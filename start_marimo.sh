#!/bin/bash

# Start Runpod base infrastructure (SSH, environment setup, etc.) in the background.
# This preserves SSH access and Runpod-specific environment initialization.
if [ -f /start.sh ]; then
    bash /start.sh &
    sleep 2
fi

# Launch marimo editor as the runpod user.
# --host 0.0.0.0  : bind to all interfaces so Runpod's proxy can reach it
# --port 2971     : marimo's default port (exposed in the Runpod template config)
# --no-token      : disable marimo's built-in token auth; authentication is
#                   handled by Runpod's proxy — do not expose port 2971 directly
# /home/runpod/workspace : open the workspace directory in the file browser
MARIMO_ARGS="edit --host 0.0.0.0 --port 2971 --no-token /home/runpod/workspace"

# uvx creates a clean isolated environment on first launch and reuses the
# cached environment on subsequent starts.
exec su -l runpod -c "uvx 'marimo[mcp,lsp]' $MARIMO_ARGS"
