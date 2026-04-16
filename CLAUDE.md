# CLAUDE.md

## Project purpose

This repo produces Docker images that run [marimo](https://marimo.io) as a notebook server on Runpod GPU and CPU pods.
A single Dockerfile is parameterized via build arguments (`BASE_IMAGE`, `VARIANT`) to produce both variants.
It is used internally by Runpod's team and published publicly as a general-purpose Runpod template, so changes are visible to external users.

## Core design principle: reproducibility

Every decision in this image should serve the goal of making notebooks fully reproducible.
Marimo runs with `--sandbox` so each notebook executes in an isolated `uv` environment built from its inline [PEP 723](https://peps.python.org/pep-0723/) script metadata.

**No domain packages should ever be pre-installed** (pandas, polars, torch, scipy, etc.).
Pre-installing packages lets users write imports that work in the pod but have no record in the notebook, silently breaking reproducibility.
This applies even when a package seems universally useful — users install what they need through marimo's package manager, which writes it into the notebook header.

## Releases

Releases are ad hoc: cut a version tag when a meaningful set of changes has accumulated.
There is no fixed cadence.
CI builds and publishes the image to GHCR automatically on `v*.*.*` tags.

## Validation

Trust CI — no local Docker build or smoke test is required before declaring work done.
GitHub Actions is the gate.

## Git workflow

Always work on a feature branch.
Never push directly to `main`.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/).
Common types: `feat`, `fix`, `chore`, `ci`, `docs`, `refactor`.

## Changelog

Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) strictly.
Bug fixes go in `Fixed` only; do not put fixes in `Changed`.
