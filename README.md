# runpod-marimo

A Docker image that runs [marimo](https://marimo.io) as a notebook server on [Runpod](https://runpod.io) GPU pods.
Marimo is served on port **2971** and is accessible via Runpod's web proxy.

## Reproducible notebooks by design

This image intentionally does **not** include marimo's `recommended` extras (polars, pandas, matplotlib, etc.).

When packages are pre-installed in the environment, users can import them without explicitly adding them as dependencies.
Those imports work fine in the pod but silently break reproducibility: the notebook has no record of what it needs, so it will fail when run anywhere else.

Instead, install packages through marimo's built-in package manager.
Marimo will write each dependency into the notebook's header using [PEP 723](https://peps.python.org/pep-0723/) inline script metadata, making the notebook self-contained and reproducible across environments.

## What is included

- **marimo** with `lsp` (in-editor autocomplete and type checking) and `mcp` extras
- **huggingface_hub** CLI for downloading models and datasets
- **GitHub CLI** (`gh`) and **runpodctl** for interacting with Runpod and GitHub from the terminal
- Standard utilities: `git`, `curl`, `wget`, `jq`, `tmux`, `nvtop`

## Building

Images are built and published to [GitHub Container Registry](https://ghcr.io) automatically when a version tag (`v*.*.*`) is pushed.

To build locally:

```bash
docker build -t runpod-marimo .
```
