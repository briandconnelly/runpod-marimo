# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-04-17

### Added

- `MARIMO_TOKEN_PASSWORD` environment variable to require a password prompt before accessing the marimo server.
  When set, the image launches marimo with `--token-password` instead of the default `--no-token`; the value is excluded from env forwarding so it does not appear in SSH or notebook shells.
- ASCII-art MOTD shown on login, with grey separator lines and purple banner text (SSH via `pam_motd`; Runpod web terminal and other non-SSH login shells via `/etc/profile.d/motd.sh`).
- Smoke test scripts (`tests/test-cpu.sh`, `tests/test-gpu.sh`, `tests/common.sh`) for validating a running pod end-to-end (marimo reachable, sandbox isolation, env forwarding, CUDA availability on GPU). Run manually against a live pod; not executed in CI.
- Variant-specific pod-template READMEs (`README-gpu.md`, `README-cpu.md`) tailored for Runpod's pod template page.

### Changed

- GPU variant is now built on `nvidia/cuda:13.2.0-runtime-ubuntu24.04` (up from the `12.x` series). This advances the CUDA major version baked into the image; notebooks that pin a specific CUDA toolkit in their PEP 723 header are unaffected.
- Renovate is pinned to the Python 3.13 series (`>=3.13 <3.14`) for `PYTHON_VERSION` updates, so the image stays on 3.13 until a deliberate major bump.

## [0.4.0] - 2026-04-16

### Added

- `PYTHON_VERSION` build arg selects the CPython version that `uv` installs into the image (Renovate-tracked).
- `UV_VERSION` build arg pins the `uv` binary copied from `ghcr.io/astral-sh/uv` (Renovate-tracked).

### Changed

- GPU variant now builds on `nvidia/cuda:*-runtime-ubuntu24.04` instead of `runpod/base`, dropping roughly 4 GB from the image.
- CPU variant now builds on `ubuntu:24.04` instead of `runpod/base`, dropping roughly 670 MB from the image.
- Python is now installed and managed by `uv` rather than inherited from the base image; no system `python3` is present.
- `uv` is now copied from the official `ghcr.io/astral-sh/uv` image at a pinned version rather than inherited from `runpod/base`.
- Pod startup no longer delegates to the base image's `/start.sh`.
  SSH setup (via `PUBLIC_KEY`) and the `/pre_start.sh` / `/post_start.sh` user hooks are now handled directly in `start_marimo.sh`.

### Fixed

- Startup no longer has a 2-second race window between the backgrounded `/start.sh` and marimo launch; services are set up synchronously before marimo starts.
- A pod with `JUPYTER_PASSWORD` set will no longer silently start Jupyter on port 8888; this image is marimo-only.

## [0.3.1] - 2026-04-16

### Added

- Renovate configuration for automated dependency update PRs covering PyPI packages (marimo, huggingface_hub, ty), GitHub release binaries (DuckDB, runpodctl), and GitHub Actions

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
