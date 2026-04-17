# runpod-marimo (GPU)

A Docker image that runs [marimo](https://marimo.io) as a notebook server on Runpod GPU pods.
Marimo is served on port **2971** and is accessible via Runpod's web proxy.

A CPU variant of this image is also published for pods without a GPU — use a tag with the `-cpu` suffix (e.g., `0.5.0-cpu`).

## Host requirements

Requires an NVIDIA GPU host with a driver supporting CUDA 12.5 or newer (Linux driver ≥ 555.42.06).
If the host driver is older, `nvidia-container-cli` will refuse to start the container with `unsatisfied condition: cuda>=12.5`.
You can check a candidate host's driver with `nvidia-smi` before launching.

## Reproducible notebooks by design

This image is designed so that every notebook is fully self-contained and reproducible anywhere.

Marimo is launched with [`--sandbox`](https://docs.marimo.io/guides/package_management/inlining_dependencies/), which runs each notebook in its own isolated `uv` environment built from the notebook's [PEP 723](https://peps.python.org/pep-0723/) inline script metadata.
When you install a package through marimo's built-in package manager, it is written directly into the notebook's header — the notebook carries its own dependency list and will run identically on any machine with `uv` installed.

This image also intentionally does **not** include marimo's `recommended` extras (polars, pandas, matplotlib, etc.).
Pre-installing packages would allow imports that work in the pod but have no record in the notebook, silently breaking reproducibility everywhere else.

## Environment variables

| Variable | Description | Default |
|---|---|---|
| `MARIMO_WORKSPACE` | Path to open in marimo's file browser | `/workspace` |
| `MARIMO_CACHE_DIR` | Parent directory for uv and Hugging Face caches | `$MARIMO_WORKSPACE/.cache` |

`/workspace` is where Runpod mounts network volumes, so notebooks created through the file browser automatically persist across pod stop/start when a volume is attached.
Without a volume, `/workspace` is a regular container directory (ephemeral).

`uv`'s sandbox cache (`UV_CACHE_DIR`) and the Hugging Face hub cache (`HF_HOME`) default to `$MARIMO_WORKSPACE/.cache/uv` and `$MARIMO_WORKSPACE/.cache/huggingface`, so downloaded notebook dependencies and models persist alongside the notebooks.
Set `MARIMO_CACHE_DIR=/home/runpod/.cache` (or any other path) to force caches onto ephemeral container storage — useful if your volume is small or you want faster local reads.
`UV_CACHE_DIR` and `HF_HOME` can be set individually to override either cache independently.

Access to the marimo server is gated by Runpod's proxy; the image launches marimo with `--no-token` and does not expose marimo's built-in authentication.

## What is included

- **CUDA runtime** — built on `nvidia/cuda:*-runtime-ubuntu24.04`, so `nvidia-smi` and the CUDA runtime libraries are available out of the box
- **nvtop** for live GPU monitoring from the terminal
- **marimo** with `lsp` (in-editor autocomplete, linting, and type checking via **ty**) and `mcp` extras
- **huggingface_hub** CLI for downloading models and datasets
- **GitHub CLI** (`gh`) and **runpodctl** for interacting with Runpod and GitHub from the terminal
- **DuckDB** CLI for querying files from the terminal
- Standard utilities: `git`, `curl`, `wget`, `jq`, `tmux`

GPU-aware Python packages (PyTorch, JAX, CuPy, etc.) are **not** pre-installed — install them from within a notebook so they are recorded in the notebook's PEP 723 header alongside the CUDA version they target.
