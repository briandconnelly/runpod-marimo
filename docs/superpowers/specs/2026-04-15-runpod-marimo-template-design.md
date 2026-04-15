# Runpod Marimo Dev Image — Design Spec

**Date:** 2026-04-15
**Status:** Approved

## Overview

A custom Runpod pod template built for AI/ML developers and researchers.
The image provides a browser-accessible [marimo](https://docs.marimo.io/) editor as the primary interface, with a curated set of CLI tools pre-installed.
Python dependency management is left to the user via [uv](https://docs.astral.sh/uv/) and marimo's native PEP 723 inline dependency support — no pre-installed data science packages.

## Base Image

`runpod/base:1.0.3-cuda1300-ubuntu2404`

- Ubuntu 24.04 with CUDA 13.0 support
- Provides `nvidia-smi` and CUDA libraries out of the box
- Provides Runpod infrastructure (SSH, env init) via `/start.sh`

## User

A non-root user `runpod` is created with:

- Home directory: `/home/runpod`
- Default shell: `/bin/bash`
- Passwordless `sudo` access (required for dev workflows that need system package installs)

All long-running services (marimo) run as `runpod`, not root.

## System Packages (apt)

| Package | Purpose |
|---------|---------|
| `git` | Version control |
| `curl` | HTTP requests, installer scripts |
| `wget` | File downloads |
| `sudo` | Privilege escalation for `runpod` user |
| `jq` | JSON processing from the CLI |
| `tmux` | Terminal multiplexer — keeps sessions alive over SSH |
| `nvtop` | Interactive GPU process monitor (complements `nvidia-smi`) |

## Additional CLI Tools

### GitHub CLI (`gh`)

Installed via the official GitHub apt repository (`cli.github.com`).
Enables authenticated GitHub operations (clone private repos, create PRs, etc.) from within the pod.

### runpodctl

Downloaded as a pre-built binary from the [runpod/runpodctl](https://github.com/runpod/runpodctl) GitHub releases (latest release resolved at build time via the GitHub API), placed at `/usr/local/bin/runpodctl`.
Provides Runpod-native operations (pod management, file transfers) from within the container.

### uv

Installed via the official installer script (`astral.sh/uv`), binary placed at `/usr/local/bin/uv`.
Available system-wide as a tool; users decide when and where to use it.
Marimo uses uv internally to resolve PEP 723 inline dependencies declared in notebooks.

## Python Tooling (uv tools)

Both tools are installed via `uv tool install`, making their binaries available in PATH without requiring a shared virtualenv.

| Tool | Binary | Purpose |
|------|--------|---------|
| `marimo` | `marimo` | Primary notebook/editor interface |
| `huggingface_hub` | `huggingface-cli` | Model/dataset downloads from the HuggingFace Hub |

No data science packages (torch, numpy, polars, etc.) are pre-installed.
Users declare per-notebook dependencies using PEP 723 inline script metadata; marimo and uv resolve them automatically.

## Workspace

`/home/runpod/workspace` is created as the default working directory for marimo.
This is where notebooks are stored and where marimo's file browser opens by default.
Users should mount a Runpod network volume at this path to persist notebooks across pod restarts.

## Startup

The Runpod base image performs its own initialization via `/start.sh` (SSH setup, environment variables, etc.).
A custom `/start_marimo.sh` script is added that:

1. Calls the base image's `/start.sh` in the background to preserve Runpod infrastructure
2. Runs `marimo edit` as the `runpod` user in the foreground

Marimo startup command:
```bash
marimo edit --host 0.0.0.0 --port 2971 --no-token /home/runpod/workspace
```

- `--host 0.0.0.0` — binds to all interfaces so Runpod's proxy can reach it
- `--port 2971` — marimo's default port
- `--no-token` — disables marimo's own token auth; Runpod's proxy handles authentication
- `/home/runpod/workspace` — opens the workspace directory in the file browser

The `CMD` of the Dockerfile is set to `/start_marimo.sh`.

## Runpod Template Configuration (set in Runpod UI)

| Setting | Value |
|---------|-------|
| Container image | `<registry>/<image>:<tag>` |
| Expose HTTP ports | `2971` |
| Container start command | *(leave blank — baked into image CMD)* |
| Volume mount path | `/home/runpod/workspace` (recommended) |

## Files Produced

| File | Purpose |
|------|---------|
| `Dockerfile` | Image definition |
| `start_marimo.sh` | Container startup script |
