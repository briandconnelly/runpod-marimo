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
_forward_env > "$POD_ENV_FILE"

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
# --host 0.0.0.0  : bind to all interfaces so Runpod's proxy can reach it
# --port 2971     : marimo's default port (exposed in the Runpod template config)
# --no-token      : disable marimo's built-in token auth; authentication is
#                   handled by Runpod's proxy — do not expose port 2971 directly
# --sandbox       : run each notebook in an isolated uv environment derived from
#                   its PEP 723 inline script metadata, ensuring reproducibility
MARIMO_ARGS="edit --host 0.0.0.0 --port 2971 --no-token --sandbox '${WORKSPACE}'"

# MARIMO_VERSION is set at build time (Dockerfile ARG → ENV → /etc/profile.d/)
# and pins the exact marimo release so the image is deterministic.
# uvx creates a clean isolated environment on first launch and reuses the
# cached environment on subsequent starts.
exec su -l runpod -c "uvx 'marimo[mcp,lsp]==${MARIMO_VERSION}' $MARIMO_ARGS"
