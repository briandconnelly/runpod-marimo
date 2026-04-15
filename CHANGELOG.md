# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Marimo is now launched with `--sandbox`, which runs each notebook in an isolated `uv` environment built from its [PEP 723](https://peps.python.org/pep-0723/) inline script metadata, ensuring every notebook is fully reproducible
- `ty` is now used as the LSP backend for in-editor type checking, powered by Astral's type checker
- DuckDB CLI (`duckdb`) is now included as a system tool for querying files from the terminal

### Removed

- Automatic `polars[gpu]` injection on GPU pods via `RUNPOD_GPU_COUNT`/`MARIMO_SKIP_GPU_POLARS`/`MARIMO_EXTRA_PACKAGES`.
  With `--sandbox` active, packages injected into the marimo server process are not available inside notebook sandboxes, so this mechanism had no effect on notebooks.

## [0.1.1] - 2026-04-15

### Added

- OCI image labels (`title`, `description`, `authors`) for registry discoverability and local build metadata
- `EXPOSE 2971` to document the marimo port
- `HEALTHCHECK` that polls marimo's HTTP endpoint to surface container health to orchestrators
- README documenting the image, its intentional package choices, and included tools

### Changed

- Marimo is now launched with `marimo[mcp,lsp]` instead of `marimo[recommended,mcp,lsp]`.
  The `recommended` extra bundles a large data science stack (polars, pandas, matplotlib, etc.) that users can import without declaring as dependencies, silently breaking notebook reproducibility.
  Users are expected to install packages explicitly via marimo's package manager so they are recorded in each notebook's header using [PEP 723](https://peps.python.org/pep-0723/) inline script metadata.
- Startup script simplified by removing the AVX2/polars-lts-cpu workaround, which was only required due to `marimo[recommended]`

## [0.1.0] - 2026-04-15

Initial release.
