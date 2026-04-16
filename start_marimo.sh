#!/bin/bash

# Start Runpod base infrastructure (SSH, environment setup, etc.) in the background.
# This preserves SSH access and Runpod-specific environment initialization.
if [ -f /start.sh ]; then
    bash /start.sh &
    sleep 2
fi

# Forward container environment variables to the runpod user's login shell.
# `su -l` (used below) starts a clean login shell that discards the parent
# process's environment. Env vars set by users when configuring their Runpod
# pod would otherwise be invisible to marimo. Writing them to a profile.d
# script (sorted last via the 99- prefix) ensures they are available and can
# override earlier defaults set at build time.
_forward_env() {
    while IFS= read -r -d '' entry; do
        local key="${entry%%=*}"
        local value="${entry#*=}"
        case "$key" in
            # System variables managed by the login shell itself
            HOME|USER|LOGNAME|SHELL|TERM|PATH|SHLVL|PWD|OLDPWD|_|HOSTNAME) continue ;;
        esac
        printf "export %s=%q\n" "$key" "$value"
    done < <(env -0)
}
_forward_env > /etc/profile.d/99-pod-env.sh

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
