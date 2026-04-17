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
#      we create it on the spot.
#
# Cache root (UV_CACHE_DIR, HF_HOME):
#   1. Individual UV_CACHE_DIR / HF_HOME if set (fine-grained user override).
#   2. MARIMO_CACHE_DIR as a grouped override (e.g. set to /home/runpod/.cache
#      to force ephemeral container-local caches even when /workspace is a
#      persistent volume).
#   3. <workspace>/.cache, so a user who attaches a volume automatically
#      gets persistent uv sandbox builds and HF downloads in addition to
#      their notebooks.

# Validate the user-supplied path knobs. A misconfigured env var ("/",
# " ", a relative path, etc.) could otherwise either chown a system
# path we take ownership of below, or land notebooks somewhere the
# user can't find them. Requiring absolute paths is a cheap guard.
_validate_path_var() {
    local name="$1" value="$2"
    if [[ -z "$value" || "$value" != /* ]]; then
        echo "Error: $name must be a non-empty absolute path; got '$value'." >&2
        exit 1
    fi
    case "$value" in
        /|/bin|/boot|/dev|/etc|/lib|/lib32|/lib64|/proc|/root|/run|/sbin|/sys|/usr|/var)
            echo "Error: $name refuses to take ownership of system path '$value'." >&2
            exit 1
            ;;
        /bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib32/*|/lib64/*|/proc/*|/root/*|/run/*|/sbin/*|/sys/*|/usr/*|/var/*)
            echo "Error: $name refuses to take ownership of a path under a system directory: '$value'." >&2
            exit 1
            ;;
    esac
}
[[ -n "${MARIMO_WORKSPACE:-}" ]] && _validate_path_var MARIMO_WORKSPACE "$MARIMO_WORKSPACE"
[[ -n "${MARIMO_CACHE_DIR:-}" ]] && _validate_path_var MARIMO_CACHE_DIR "$MARIMO_CACHE_DIR"

# Ensure a directory exists and is owned by the runpod user. Only chowns
# directories we created on this boot, to avoid changing ownership of
# a pre-existing user-supplied path (e.g. a populated volume subdir).
# Special case: /workspace itself is always chown'd because Runpod mounts
# network volumes there root-owned, and marimo (unprivileged) must be
# able to write at the top level.
_ensure_runpod_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        if [[ "$dir" == "/workspace" ]]; then
            chown runpod:runpod "$dir" || {
                echo "Warning: could not chown '$dir' to runpod; marimo may fail to write notebooks." >&2
            }
        fi
    else
        mkdir -p "$dir" || {
            echo "Error: failed to create '$dir'." >&2
            exit 1
        }
        chown runpod:runpod "$dir" || {
            echo "Error: failed to chown '$dir' to runpod." >&2
            exit 1
        }
    fi
}

WORKSPACE="${MARIMO_WORKSPACE:-/workspace}"
_ensure_runpod_dir "$WORKSPACE"

CACHE_ROOT="${MARIMO_CACHE_DIR:-${WORKSPACE}/.cache}"
# These exports are load-bearing — they flow into the parent process's
# env, get captured by _forward_env below, and from there land in
# /etc/profile.d/zz-pod-env.sh so marimo's `su -l runpod` login shell
# (which would otherwise wipe them) picks them up. Do not move this
# block after _forward_env without re-wiring the propagation.
export UV_CACHE_DIR="${UV_CACHE_DIR:-$CACHE_ROOT/uv}"
export HF_HOME="${HF_HOME:-$CACHE_ROOT/huggingface}"
_ensure_runpod_dir "$CACHE_ROOT"
_ensure_runpod_dir "$UV_CACHE_DIR"
_ensure_runpod_dir "$HF_HOME"

# Probe that the workspace is actually usable by the runpod user before
# launching marimo. The dir-setup above should guarantee this, but a
# network volume with restrictive ACLs, an immutable bit, or a
# read-only mount can all leave us in a state where marimo launches
# fine but fails to save the first notebook — the exact failure mode
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
