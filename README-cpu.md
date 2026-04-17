# runpod-marimo (CPU)

A Docker image that runs [marimo](https://marimo.io) as a notebook server on Runpod CPU pods.
Marimo is served on port **2971** and is accessible via Runpod's web proxy.

A GPU variant of this image is also published for CUDA-enabled pods — use a tag without the `-cpu` suffix (e.g., `0.5.0`).

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
| `MARIMO_CACHE_DIR` | Parent directory for `uv` and Hugging Face caches | `/home/runpod/.cache` |

`/workspace` is where Runpod mounts network volumes, so notebooks created through the file browser automatically persist across pod stop/start when a volume is attached.
Without a volume, `/workspace` is a regular container directory (ephemeral).

### Persisting the caches

By default `uv`'s notebook-sandbox cache (`UV_CACHE_DIR`) and the Hugging Face hub cache (`HF_HOME`) live under `/home/runpod/.cache`, which is ephemeral container storage — any downloaded notebook dependencies or model files are lost on pod rebuild.
The image ships with `uvx marimo` pre-cached at this location, so first-boot launches remain instant.

To keep the caches on a network volume so model and dependency downloads survive pod restarts, set `MARIMO_CACHE_DIR` to a path on the volume before starting the pod:

```
MARIMO_CACHE_DIR=/workspace/.cache
```

`UV_CACHE_DIR` and `HF_HOME` derive from `MARIMO_CACHE_DIR` (`$MARIMO_CACHE_DIR/uv` and `$MARIMO_CACHE_DIR/huggingface`), or can be set individually to point each cache at a different location.
The first notebook opened after enabling this pays a one-time download cost to repopulate the cache on the volume; subsequent boots reuse it.

Access to the marimo server is gated by Runpod's proxy; the image launches marimo with `--no-token` and does not expose marimo's built-in authentication.

## What is included

- **marimo** with `lsp` (in-editor autocomplete, linting, and type checking via **ty**) and `mcp` extras
- **huggingface_hub** CLI for downloading models and datasets
- **GitHub CLI** (`gh`) and **runpodctl** for interacting with Runpod and GitHub from the terminal
- **DuckDB** CLI for querying files from the terminal
- Standard utilities: `git`, `curl`, `wget`, `jq`, `tmux`
