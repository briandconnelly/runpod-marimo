# runpod-marimo

A Docker image that runs [marimo](https://marimo.io) as a notebook server on [Runpod](https://runpod.io) GPU and CPU pods.
Marimo is served on port **2971** and is accessible via Runpod's web proxy.

## Variants

The image is published in two variants from a single Dockerfile:

| Variant | Base image | Tag examples |
|---|---|---|
| GPU | `nvidia/cuda:*-runtime-ubuntu24.04` | `0.5.0`, `0.5`, `0.5.0-gpu`, `0.5-gpu` |
| CPU | `ubuntu:24.04` | `0.5.0-cpu`, `0.5-cpu` |

Bare version tags (without a `-gpu` or `-cpu` suffix) resolve to the GPU variant.

The [GPU](README-gpu.md) and [CPU](README-cpu.md) variants each have a dedicated README tailored for Runpod's pod template page.

## Reproducible notebooks by design

This image is designed so that every notebook is fully self-contained and reproducible anywhere.

Marimo is launched with [`--sandbox`](https://docs.marimo.io/guides/package_management/inlining_dependencies/), which runs each notebook in its own isolated `uv` environment built from the notebook's [PEP 723](https://peps.python.org/pep-0723/) inline script metadata.
When you install a package through marimo's built-in package manager, it is written directly into the notebook's header — the notebook carries its own dependency list and will run identically on any machine with `uv` installed.

This image also intentionally does **not** include marimo's `recommended` extras (polars, pandas, matplotlib, etc.).
Pre-installing packages would allow imports that work in the pod but have no record in the notebook, silently breaking reproducibility everywhere else.

## Environment variables

| Variable | Description | Default |
|---|---|---|
| `MARIMO_WORKSPACE` | Path to open in marimo's file browser | `/home/runpod/workspace` |
| `MARIMO_TOKEN_PASSWORD` | If set, marimo prompts for this password before granting access. When unset, no prompt is shown and authentication is delegated to Runpod's proxy. | *(unset)* |

When `MARIMO_TOKEN_PASSWORD` is set, the value is passed as a CLI argument to marimo and is visible on the process command line (`ps`, `/proc/<pid>/cmdline`) to anyone with shell access on the pod.
On a single-user Runpod pod this is generally acceptable — the user already has root — but treat it as a second factor layered on top of the Runpod proxy, not a secret hardened against local inspection.
The value is not written into `/etc/profile.d/` and does not appear in SSH sessions or notebook shells.

## What is included

- **marimo** with `lsp` (in-editor autocomplete, linting, and type checking via **ty**) and `mcp` extras
- **huggingface_hub** CLI for downloading models and datasets
- **GitHub CLI** (`gh`) and **runpodctl** for interacting with Runpod and GitHub from the terminal
- **DuckDB** CLI for querying files from the terminal
- Standard utilities: `git`, `curl`, `wget`, `jq`, `tmux`
- **nvtop** for GPU monitoring (GPU variant only)

## Building

Images are built and published to [GitHub Container Registry](https://ghcr.io) automatically when a version tag (`v*.*.*`) is pushed.

To build locally:

```bash
# GPU (default)
docker build -t runpod-marimo:gpu .

# CPU
docker build -t runpod-marimo:cpu \
  --build-arg VARIANT=cpu \
  --build-arg "IMAGE_DESCRIPTION=Marimo notebook server for Runpod CPU pods" .
```
