# runpod-marimo (GPU)

A Docker image that runs [marimo](https://marimo.io) as a notebook server on Runpod GPU pods, served on port **2971** via Runpod's web proxy.
A CPU variant is published with a `-cpu` tag suffix (e.g., `0.11.0-cpu`).
Source: [GitHub](https://github.com/briandconnelly/runpod-marimo) · [Report a bug or request a feature](https://github.com/briandconnelly/runpod-marimo/issues)

## Host requirements

Requires an NVIDIA driver supporting CUDA 12.9 (Linux driver >= 575), or a 535/550/560/565/570-series driver via CUDA forward compatibility — otherwise the container refuses to start with `unsatisfied condition: cuda>=12.9`.

## Reproducible notebooks by design

Marimo is launched with [`--sandbox`](https://docs.marimo.io/guides/package_management/inlining_dependencies/), so each notebook runs in its own isolated `uv` environment built from its [PEP 723](https://peps.python.org/pep-0723/) inline script metadata.
Packages installed through marimo's package manager are written into the notebook's header, so it carries its own dependency list and runs identically on any machine with `uv`.

No domain packages are pre-installed — neither marimo's `recommended` extras (pandas, polars, matplotlib) nor GPU packages (PyTorch, JAX, CuPy).
Pre-installing them would allow imports that work in the pod but leave no record in the notebook.

## Environment variables

| Variable | Description | Default |
|---|---|---|
| `MARIMO_WORKSPACE` | Path to open in marimo's file browser | `/workspace` |
| `MARIMO_CACHE_DIR` | Parent directory for uv and Hugging Face caches | `$MARIMO_WORKSPACE/.cache` |
| `MARIMO_TOKEN_PASSWORD` | Password required to access the marimo UI | _(falls back to `JUPYTER_PASSWORD`, else a generated token)_ |

`/workspace` is where Runpod mounts network volumes, so notebooks created there persist across pod stop/start when a volume is attached (otherwise it is ephemeral).
The `uv` sandbox cache (`UV_CACHE_DIR`) and Hugging Face hub cache (`HF_HOME`) default to `$MARIMO_CACHE_DIR/uv` and `$MARIMO_CACHE_DIR/huggingface`, so dependencies and models persist alongside the notebooks; either can be set on its own.
Set `MARIMO_CACHE_DIR=/home/runpod/.cache` for ephemeral container-local caches; first boot still hits the image's prewarmed `uvx marimo` cache.
`HF_HOME` holds your Hugging Face login token, so keep it off a volume shared between pods.

## Authentication

Runpod's web proxy does **not** authenticate requests — anyone with the pod's proxy URL (`https://<pod-id>-2971.proxy.runpod.net`) can reach the marimo server, which is arbitrary code execution.
Token authentication is therefore always on (it cannot be disabled), with the password resolved in order:

1. `MARIMO_TOKEN_PASSWORD`, if set — an explicit password of your choosing.
2. `JUPYTER_PASSWORD`, if set — Runpod auto-generates this for templates that declare it. Never shown in the console, but it survives pod stop/start, so a bookmarked access URL keeps working.
3. A random token generated at startup (new on every restart).

The startup logs (Runpod console) print a ready-to-use access URL (`.../?access_token=...`).
It is also stored at `/home/runpod/.config/marimo/token` and exported as `MARIMO_TOKEN` into login and interactive shells for agents in the pod.

marimo runs as `runpod`, but that is hygiene, not a sandbox: `runpod` has passwordless `sudo apt-get` (root-equivalent) and console/SSH shells are root.

## What is included

- **CUDA runtime** — built on `nvidia/cuda:*-runtime-ubuntu24.04`, so `nvidia-smi` and the CUDA libraries work out of the box
- **nvtop** for live GPU monitoring
- **marimo** with the `lsp` (autocomplete, linting, and type checking via **ty**) and `mcp` extras
- **[marimo-pair](https://github.com/marimo-team/marimo-pair)** agent skill for driving the live notebook kernel
- **huggingface_hub**, **GitHub CLI** (`gh`), **runpodctl**, and **DuckDB** CLIs
- **[pi](https://pi.dev)** and **[opencode](https://opencode.ai)** coding-agent CLIs
- Standard utilities: `git`, `curl`, `wget`, `jq`, `tmux`

## Pairing with a coding agent

The preinstalled [pi](https://pi.dev) and [opencode](https://opencode.ai) agents pick up the bundled [marimo-pair](https://github.com/marimo-team/marimo-pair) skill, which runs Python in the *same kernel you are using* instead of editing the file behind the running kernel's back; it is also linked into `~/.claude/skills/` and `~/.agents/skills/` for any agent you bring.
Set your provider's API key as a pod env var (e.g. `ANTHROPIC_API_KEY`), point the agent at `http://localhost:2971` explicitly, and it authenticates with the exported `MARIMO_TOKEN`.
Non-interactive shells and other details are in the [repository README](https://github.com/briandconnelly/runpod-marimo#pairing-with-a-coding-agent).
