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

if grep -q avx2 /proc/cpuinfo; then
    # Standard path: uvx creates a clean isolated environment on first launch
    # and reuses the cached environment on subsequent starts.
    exec su -l runpod -c "uvx 'marimo[recommended,mcp,lsp]' $MARIMO_ARGS"
else
    # No AVX2 (e.g. Apple Silicon running this image under Rosetta).
    # polars from marimo[recommended] is compiled with AVX2 and will crash.
    # Build an explicit venv and overwrite polars with the CPU-compatible build.
    # uvx --with polars-lts-cpu is insufficient because standard polars (as a
    # direct marimo dependency) wins the resolution and its files take precedence.
    echo "WARNING: AVX2 not detected — building polars-lts-cpu compatible environment"
    MARIMO_VENV=/home/runpod/.marimo-venv
    if [ ! -d "$MARIMO_VENV" ]; then
        su -l runpod -c "
            set -e
            uv venv --python 3.12 $MARIMO_VENV
            # polars-lts-cpu stable tops out at 1.33.1. Pin polars to the same
            # version so all marimo[recommended] dependencies resolve against the
            # same API — without this, packages like connectorx resolve against
            # the newer polars and break at import time with missing symbol errors.
            # Update this pin when a newer polars-lts-cpu stable is released.
            uv pip install --python $MARIMO_VENV 'marimo[recommended,mcp,lsp]' 'polars==1.33.1'
            uv pip install --python $MARIMO_VENV 'polars-lts-cpu==1.33.1'
        " || { echo "ERROR: Failed to build marimo environment" >&2; exit 1; }
    fi
    exec su -l runpod -c "$MARIMO_VENV/bin/marimo $MARIMO_ARGS"
fi
