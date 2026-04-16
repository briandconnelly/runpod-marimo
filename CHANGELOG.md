# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.1] - 2026-04-16

### Fixed

- Environment variables set by users when configuring a pod are now visible to the marimo notebook session.
  Previously, `su -l` discarded the container's environment when switching to the `runpod` user, making user-specified env vars invisible to notebooks.

## [0.3.0] - 2026-04-15

### Added

- CPU variant of the Docker image (`-cpu` tag suffix) using `runpod/base:1.0.3-ubuntu2404`
- CI now builds and validates both GPU and CPU variants

## [0.2.0] - 2026-04-15

### Added

- Marimo is now launched with `--sandbox`, which runs each notebook in an isolated `uv` environment built from its [PEP 723](https://peps.python.org/pep-0723/) inline script metadata, ensuring every notebook is fully reproducible
- `ty` is now used as the LSP backend for in-editor type checking, powered by Astral's type checker
- DuckDB CLI (`duckdb`) is now included as a system tool for querying files from the terminal
- SHA256 checksum verification for DuckDB and runpodctl binary downloads
- CI workflow that validates the Docker build on pull requests

### Changed

- Marimo, huggingface_hub, and ty are now pinned to explicit versions (`0.23.1`, `1.10.2`, `0.0.31`) for deterministic, reproducible builds
- `runpod` user sudo access is now scoped to `apt-get` and `apt` instead of unrestricted `NOPASSWD:ALL`

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
