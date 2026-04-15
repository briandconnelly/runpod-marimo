#!/bin/bash

# Start Runpod base infrastructure (SSH, environment setup, etc.) in the background.
# This preserves SSH access and Runpod-specific environment initialization.
if [ -f /start.sh ]; then
    bash /start.sh &
    sleep 2
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
MARIMO_ARGS="edit --host 0.0.0.0 --port 2971 --no-token --sandbox ${WORKSPACE}"

# uvx creates a clean isolated environment on first launch and reuses the
# cached environment on subsequent starts.
exec su -l runpod -c "uvx 'marimo[mcp,lsp]' $MARIMO_ARGS"
