#!/bin/bash
set -u

# Optional user hook that runs before services (SSH, env forwarding) start.
# Treated as a required setup step: any failure aborts startup.
if [[ -f /pre_start.sh ]]; then
    echo "Running /pre_start.sh..."
    if ! bash /pre_start.sh; then
        echo "Error: /pre_start.sh failed; aborting startup." >&2
        exit 1
    fi
fi

# If the pod was launched with a PUBLIC_KEY (standard Runpod convention),
# authorize it for root and start sshd. DSA is intentionally omitted — it is
# deprecated since OpenSSH 7.0 and unavailable in recent releases.
# SSH failures abort: a user who provided PUBLIC_KEY expects to be able to
# SSH in, so silent failure would be worse than an explicit exit.
if [[ -n "${PUBLIC_KEY:-}" ]]; then
    echo "Setting up SSH..."
    mkdir -p /root/.ssh
    # Idempotent: avoid duplicate entries across pod stop/start cycles.
    touch /root/.ssh/authorized_keys
    if ! grep -Fxq -- "$PUBLIC_KEY" /root/.ssh/authorized_keys; then
        printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
    fi
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys

    for keytype in rsa ecdsa ed25519; do
        keyfile="/etc/ssh/ssh_host_${keytype}_key"
        if [[ ! -f "$keyfile" ]]; then
            if ! ssh-keygen -t "$keytype" -f "$keyfile" -q -N ''; then
                echo "Error: failed to generate SSH host key '$keyfile'" >&2
                exit 1
            fi
        fi
    done

    # On Ubuntu 24.04 openssh-server relies on systemd to create /run/sshd
    # via a RuntimeDirectory= unit directive. In a non-systemd container,
    # that directory is never created and sshd fails with "Missing privilege
    # separation directory". Create it explicitly before starting the service.
    mkdir -p /run/sshd

    if ! service ssh start; then
        echo "Error: failed to start sshd after PUBLIC_KEY was provided" >&2
        exit 1
    fi
fi

# ── Workspace and cache directories ──────────────────────────────────────────
# marimo's file browser opens to WORKSPACE. Notebooks and the per-sandbox
# uv caches and HF model downloads are rooted here so a Runpod network
# volume attached at /workspace persists everything across pod stop/start.
#
# WORKSPACE selection:
#   1. MARIMO_WORKSPACE if set (user override).
#   2. /workspace unconditionally, matching Runpod's volume-mount convention.
#      When no volume is attached /workspace is just a fresh container dir;
#      install -d creates it on the spot. Ownership of the top-level mount
#      point is set to the runpod user (non-recursive) so marimo — which
#      runs unprivileged — can create new files; existing files on a
#      populated volume keep their owner and mode.
#
# Cache root (UV_CACHE_DIR, HF_HOME):
#   1. Individual UV_CACHE_DIR / HF_HOME if set (fine-grained user override).
#   2. MARIMO_CACHE_DIR as a grouped override — the documented knob for
#      persisting caches on a network volume, e.g.
#      MARIMO_CACHE_DIR=/workspace/.cache.
#   3. /home/runpod/.cache, ephemeral container storage. This matches
#      uv's built-in default and where the build-time uvx marimo cache
#      is warmed, so first-boot uvx launches are a cache hit. Downloaded
#      notebook deps and HF models are lost on pod rebuild; users who
#      want persistence opt in via MARIMO_CACHE_DIR.
#
# This block runs before _forward_env below so the computed cache paths
# flow into /etc/profile.d/zz-pod-env.sh for login shells.
WORKSPACE="${MARIMO_WORKSPACE:-/workspace}"
install -d -o runpod -g runpod "$WORKSPACE"

CACHE_ROOT="${MARIMO_CACHE_DIR:-/home/runpod/.cache}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$CACHE_ROOT/uv}"
export HF_HOME="${HF_HOME:-$CACHE_ROOT/huggingface}"
install -d -o runpod -g runpod "$CACHE_ROOT" "$UV_CACHE_DIR" "$HF_HOME"

# Probe that the workspace is actually usable by the runpod user before
# launching marimo. install -d above should guarantee this, but a network
# volume with restrictive ACLs, an immutable bit, or a read-only mount
# can all silently leave us in a state where marimo launches fine but
# fails to save the first notebook — which is exactly the failure mode
# this image is meant to prevent. Directories need both the write bit
# and the execute (search) bit for file creation, so check both.
WORKSPACE_Q_PROBE=$(printf '%q' "$WORKSPACE")
if ! su -l runpod -c "test -w $WORKSPACE_Q_PROBE && test -x $WORKSPACE_Q_PROBE"; then
    echo "Error: workspace '$WORKSPACE' is not writable by the runpod user." >&2
    echo "       Check mount permissions, ACLs, or set MARIMO_WORKSPACE to a usable path." >&2
    exit 1
fi
unset WORKSPACE_Q_PROBE

# Forward container environment variables to the runpod user's login shell.
# `su -l` (used below) starts a clean login shell that discards the parent
# process's environment. Env vars set by users when configuring their Runpod
# pod would otherwise be invisible to marimo. Writing them to a profile.d
# script ensures they are available. The zz- prefix makes it sort after
# runpod-env.sh so user overrides take precedence over build-time defaults
# (in C locale, digits sort before letters, so a numeric prefix would not
# achieve this).
_forward_env() {
    while IFS= read -r -d '' entry; do
        local key="${entry%%=*}"
        local value="${entry#*=}"
        case "$key" in
            # System variables managed by the login shell itself
            HOME|USER|LOGNAME|SHELL|TERM|PATH|SHLVL|PWD|OLDPWD|_|HOSTNAME) continue ;;
            # Bash readonly variables that would error on re-export
            BASHOPTS|SHELLOPTS) continue ;;
            # Consumed at boot by SSH setup / unused Jupyter hook; credentials
            # or startup-only and have no use in the notebook env.
            # MARIMO_TOKEN_PASSWORD is a legacy variable from 0.5.0-0.5.1
            # that older pod templates may still set; keep it out of the
            # login-shell environment even though the feature is gone.
            PUBLIC_KEY|JUPYTER_PASSWORD|MARIMO_TOKEN_PASSWORD) continue ;;
        esac
        # Skip entries that aren't valid shell identifiers (e.g. BASH_FUNC_*%%)
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        printf "export %s=%q\n" "$key" "$value"
    done < <(env -0)
}
POD_ENV_FILE="/etc/profile.d/zz-pod-env.sh"
install -o root -g runpod -m 0640 /dev/null "$POD_ENV_FILE" || {
    echo "Failed to create $POD_ENV_FILE with secure permissions" >&2
    exit 1
}
if ! _forward_env > "$POD_ENV_FILE"; then
    echo "Failed to write forwarded environment to $POD_ENV_FILE" >&2
    exit 1
fi

# Optional user hook that runs after services are up and before marimo starts.
# Failures are logged but do not block marimo startup — a post-start hook that
# breaks should not prevent the notebook server from coming up.
if [[ -f /post_start.sh ]]; then
    echo "Running /post_start.sh..."
    if ! bash /post_start.sh; then
        echo "Warning: /post_start.sh failed; continuing to start marimo." >&2
    fi
fi

# Launch marimo editor as the runpod user.
# --host 0.0.0.0 : bind to all interfaces so Runpod's proxy can reach it
# --port 2971    : marimo's default port (exposed in the Runpod template config)
# --no-token     : disable marimo's built-in token auth; authentication is handled
#                  by Runpod's proxy — do not expose port 2971 directly. Token auth
#                  cannot be used with the Runpod web proxy: marimo builds login
#                  redirect Location headers from the request's Host, which Runpod
#                  sets to an unreachable internal overlay address, so browsers get
#                  303'd to a URL they can't resolve.
# --sandbox      : run each notebook in an isolated uv environment derived from
#                  its PEP 723 inline script metadata, ensuring reproducibility
#
# MARIMO_ARGS is interpolated into `su -l runpod -c "uvx ... $MARIMO_ARGS"` below,
# so the string is re-parsed as a shell command by the su-invoked shell. The
# workspace path is pre-escaped with `printf %q` so special characters survive
# that second parse unchanged and cannot inject commands — this script runs as
# root, so unescaped interpolation of user-controlled env vars would be a
# privilege-escalation hole.
WORKSPACE_Q=$(printf '%q' "$WORKSPACE")
MARIMO_ARGS="edit --host 0.0.0.0 --port 2971 --no-token --sandbox ${WORKSPACE_Q}"

# MARIMO_VERSION is set at build time (Dockerfile ARG → ENV → /etc/profile.d/)
# and pins the exact marimo release so the image is deterministic.
# uvx creates a clean isolated environment on first launch and reuses the
# cached environment on subsequent starts.
# Pre-escape the full package spec: `printf %q` protects both the version
# value and the `[mcp,lsp]` glob characters from re-expansion by the su -l
# shell, avoiding command injection through MARIMO_VERSION and spurious
# glob matches against the runpod user's cwd.
MARIMO_SPEC_Q=$(printf '%q' "marimo[mcp,lsp]==${MARIMO_VERSION}")
exec su -l runpod -c "uvx ${MARIMO_SPEC_Q} $MARIMO_ARGS"
