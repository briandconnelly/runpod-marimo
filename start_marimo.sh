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
            PUBLIC_KEY|JUPYTER_PASSWORD) continue ;;
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

# Workspace directory opened in the marimo file browser.
WORKSPACE="${MARIMO_WORKSPACE:-/home/runpod/workspace}"

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
