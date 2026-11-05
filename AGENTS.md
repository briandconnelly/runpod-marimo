# Runpod Marimo Templates

## Project purpose

This repo produces Docker images that run [marimo](https://marimo.io) as a notebook server on Runpod GPU and CPU pods.
A single Dockerfile produces both variants: the `VARIANT` build argument (`gpu` or `cpu`) selects a `base-gpu` (`nvidia/cuda:${CUDA_BASE_TAG}`) or `base-cpu` (`ubuntu:${UBUNTU_BASE_TAG}`) stage.
It is used internally by Runpod's team and published publicly as a general-purpose Runpod template, so changes are visible to external users.

## Core design principle: reproducibility

Every decision in this image should serve the goal of making notebooks fully reproducible.
Marimo runs with `--sandbox` so each notebook executes in an isolated `uv` environment built from its inline [PEP 723](https://peps.python.org/pep-0723/) script metadata.

**No domain packages should ever be pre-installed** (pandas, polars, torch, scipy, etc.).
Pre-installing packages lets users write imports that work in the pod but have no record in the notebook, silently breaking reproducibility.
This applies even when a package seems universally useful — users install what they need through marimo's package manager, which writes it into the notebook header.

The boundary is "nothing may become importable from a notebook's sandbox."
Standalone CLIs and isolated `uv tool install`s (huggingface_hub, ty) are allowed because a notebook cannot import them.
Never add a Python package to marimo's `uvx` environment beyond `marimo[mcp,lsp]`, and keep that requirement set identical between the Dockerfile prewarm and `start_marimo.sh`, or first boot stops being a cache hit.

## Security stance

Token authentication stays on by default; Runpod's web proxy authenticates nothing, and a notebook server is arbitrary code execution.
The resolved token never goes on a command line (it travels via `--token-password-file`).
The `runpod` user is hygiene, not a security boundary: its `sudo apt-get` grant is root-equivalent, and the pod is single-tenant.
Do not describe it as a sandbox.

## Adding a pinned tool

Every downloaded binary follows one pattern; `scripts/sync-checksums.sh` and Renovate both depend on it:

- A `# renovate: datasource=… depName=…` comment directly above `ARG <TOOL>_VERSION=…`.
- A sibling `ARG <TOOL>_SHA256=…` verified with `sha256sum -c` in the same `RUN`. Put any placeholder value in it; CI computes the real one.
- The tool's LICENSE under `/usr/share/licenses/<tool>/`. If the release tarball has none, fetch it from the same tag as a second pinned download named `<TOOL>_LICENSE_SHA256`.
- Smoke checks in `tests/common.sh` that execute the binary (`--version`) as both `root` and `runpod`.

Do not bump by hand the pins that `renovate.json` constrains: Python stays on 3.13.x, and `nvidia/cuda` stays below 13 until fleet driver coverage is checked.

## Pod-template READMEs

`README-gpu.md` and `README-cpu.md` are pasted into Runpod's pod-template description field, which is capped at **5000 characters**.
Keep both under it — after editing either one, run:

```sh
scripts/check-readme-length.sh
```

CI's `lint` job runs the same check on every pull request.
It measures bytes rather than characters, which is the conservative bound: a UTF-8 byte count is never below the character count.
`README.md` is the long-form documentation and has no limit; when trimming a variant README, move the detail there (or confirm it is already there) and link to the repository rather than deleting it.
`README-gpu.md` sits within a few bytes of the cap; any addition needs an offsetting cut.

## Releases

Pushing a `v*.*.*` tag builds and publishes both variants to GHCR.
Agents never push tags.

A release is a `chore(release): X.Y.Z` pull request that moves `[Unreleased]` into a dated section, backfills version lines that Renovate PRs skipped, and refreshes the tag examples in `README.md`, `README-gpu.md`, and `README-cpu.md`.

### Pre-release checklist

CI only smoke-tests the CPU variant (GitHub has no GPU runners), yet bare version tags resolve to the GPU variant — so the GPU image must be validated manually against a live pod before every release:

1. Push the release-candidate image to a registry and launch a Runpod GPU pod from it.
2. Confirm in the Runpod console that the pod's port 2971 reaches **Ready** and the marimo UI is reachable through the web proxy with the resolved access token. (Token auth once broke the proxy's readiness probe — see the 0.5.2 changelog entry — so this must be re-verified through the real proxy, not just with local curl.)
3. Open and run a notebook in the browser, then run `tests/run-remote.sh <ssh-target> gpu`. The sandbox-isolation and ctypes CUDA sections skip silently without an open notebook; require them to run, and read the printed summary for zero failures.

## Validation

No local Docker build is required for pull-request work; report the actual CI result, or say it is pending.
CI builds both variants but smoke-tests only the CPU image, with ephemeral caches, so it does not cover GPU, the Runpod proxy, or the default persistent-cache cold boot.
Docs-only PRs (`*.md`, `.gitignore`, `.claude/`, `renovate.json`) skip the build entirely; a green check there says nothing about the image.
The `main` ruleset does not require status checks, so CI reports but does not block.

Cheap checks to run before pushing:

```sh
shellcheck -x -P SCRIPTDIR start_marimo.sh scripts/*.sh tests/*.sh
hadolint Dockerfile
```

Do not hand-edit the `_SHA256` ARGs in the Dockerfile when bumping a tool's version.
Change the `_VERSION` ARG only; CI's `checksums` job recomputes the hash and commits it to the branch.
Run `scripts/sync-checksums.sh --base origin/main` locally if you want the same fix before pushing; `--base` is the tag-mutation interlock, so always pass it when rewriting pins.
If that job fails rather than fixing the pin, do not paste in the hash it printed — it refuses to auto-update a checksum whose version did not change, which means upstream altered an already-released tag.

On same-repository PRs, CI pushes a `chore: sync pinned download checksums` commit to the branch, so run `git pull --rebase` before pushing again.
Fork PRs only get a check, not a repair.

## Git workflow

Always work on a feature branch.
Never push directly to `main`.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/).
Common types: `feat`, `fix`, `chore`, `ci`, `docs`, `refactor`.

## Changelog

Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) strictly.
Bug fixes go in `Fixed` only; do not put fixes in `Changed`.
Every PR with a user-visible change (image contents, startup behavior, CI behavior, READMEs) adds an entry under `[Unreleased]` in the same PR; Renovate's own PRs do not, and the release PR backfills them.
Version bumps are one `Changed` line each (`Updated <tool> to <version>.`, with "(major version)" where it applies).
Entries describe user-visible behavior and explain why.
