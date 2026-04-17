# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.2] - 2026-04-17

### Removed

- `MARIMO_TOKEN_PASSWORD` environment variable and the associated `--token-password` launch mode.
  Marimo builds its login-redirect `Location` header from the incoming request's `Host`, which Runpod's web proxy sets to an internal overlay address (e.g., `100.65.x.x:60830`) that browsers cannot reach.
  Pods launched with the variable set got stuck at "Initializing..." in the Runpod console because the proxy probe on `/` received a 303 to an unreachable URL.
  Marimo's `--proxy` flag does not affect redirect URL construction (and crashes at startup when passed a full URL).
  Access control reverts to Runpod's proxy gating; users who want a password layer can SSH in and port-forward 2971 locally.

### Fixed

- GPU and CPU pods launched with `MARIMO_TOKEN_PASSWORD` set no longer fail to become reachable through Runpod's web proxy.
  The feature was removed (see above); without it, marimo returns 200 on `/` and the proxy marks the port Ready.

## [0.5.1] - 2026-04-17

### Added

- `tests/run-remote.sh <ssh-target> [cpu|gpu]` helper for running the smoke-test suite against a live pod. Works around Runpod's SSH proxy rejecting `scp` and inline command exec by shipping `tests/` as a base64 tarball through a PTY.

### Changed

- GPU variant now builds on `nvidia/cuda:12.5.1-runtime-ubuntu24.04` (down from `13.2.0`). Runpod's fleet driver distribution meant 0.5.0's CUDA 13.2 baseline was supported by essentially 0% of hosts; 12.5.1 covers ~82% of the fleet while keeping the Ubuntu 24.04 OS baseline (NVIDIA does not publish `12.4` runtime images on Ubuntu 24.04). Notebooks that need a newer CUDA runtime pull it in via their PEP 723 headers and are unaffected.
- Renovate is pinned to the CUDA 12.x series (`allowedVersions: <13`) for `nvidia/cuda` updates, so future bumps to CUDA 13.x require an explicit fleet-coverage check before merging.
- GPU variant now removes the orphaned `/cuda-keyring_1.1-1_all.deb` installer left behind by the upstream `nvidia/cuda` base image.
- marimo's uvx tool environment is now pre-populated at build time, eliminating the ~1-2 minute first-boot wait while uvx downloaded and installed `marimo[mcp,lsp]`. The cache key is the exact spec string, so users who override `MARIMO_VERSION` at runtime still pay the install cost once for their version.
- `HEALTHCHECK --start-period` raised from 60s to 120s for extra headroom on slow cold starts.

### Fixed

- GPU pods on hosts with CUDA driver < 13.2 failed to start with `nvidia-container-cli: requirement error: unsatisfied condition: cuda>=13.2`. The CUDA base downgrade above restores compatibility with the overwhelming majority of Runpod's fleet.

### Removed

- ASCII-art MOTD and its `/etc/profile.d/motd.sh` hook. The Runpod SSH proxy execs bash directly into the container without going through `sshd` / PAM and without a login shell, so neither `pam_motd` nor `/etc/profile.d/*.sh` ever ran — the banner was never actually shown on the primary login path.

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
