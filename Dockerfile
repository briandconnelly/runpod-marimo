# ── Base image selection ─────────────────────────────────────────────────────
# GPU variant: upstream NVIDIA CUDA runtime on Ubuntu 24.04
# CPU variant: plain Ubuntu 24.04
# VARIANT is passed at build time; the matching base stage is selected below.
# renovate: datasource=docker depName=nvidia/cuda
ARG CUDA_BASE_TAG=12.9.2-runtime-ubuntu24.04
# renovate: datasource=docker depName=ubuntu
ARG UBUNTU_BASE_TAG=24.04
# renovate: datasource=docker depName=ghcr.io/astral-sh/uv
ARG UV_VERSION=0.12.0
ARG VARIANT=gpu

# Named stage for the uv binary distribution. A named stage is used rather
# than `COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION}` because BuildKit does
# not reliably expand ARGs in the image reference of a COPY --from.
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-dist

FROM nvidia/cuda:${CUDA_BASE_TAG} AS base-gpu
FROM ubuntu:${UBUNTU_BASE_TAG} AS base-cpu
# hadolint ignore=DL3006  # base-${VARIANT} is a named stage above, not an untagged image
FROM base-${VARIANT}

# Fail RUN pipelines on the first broken stage instead of only the last;
# also satisfies hadolint DL4006 for the checksum-verified downloads below.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Re-declare ARGs that need to be visible after the final FROM.
# IMAGE_VERSION is intentionally declared and consumed at the bottom of the
# stage so a version bump only invalidates the final LABEL layer instead of
# everything downstream of it.
ARG VARIANT
ARG IMAGE_DESCRIPTION="Marimo notebook server for Runpod GPU pods"
# renovate: datasource=python-version depName=python
ARG PYTHON_VERSION=3.13.15
# renovate: datasource=pypi depName=marimo
ARG MARIMO_VERSION=0.23.15
# renovate: datasource=pypi depName=huggingface_hub
ARG HUGGINGFACE_HUB_VERSION=1.25.1
# renovate: datasource=pypi depName=ty
ARG TY_VERSION=0.0.64

LABEL org.opencontainers.image.title="runpod-marimo" \
      org.opencontainers.image.description="${IMAGE_DESCRIPTION}" \
      org.opencontainers.image.authors="brian.connelly@runpod.io"

# Ensure Python output is immediately flushed to logs
ENV PYTHONUNBUFFERED=1

# ── System packages ──────────────────────────────────────────────────────────
# ca-certificates + curl are required for the tool downloads below.
# openssh-server provides sshd and the /etc/init.d/ssh script used by
# start_marimo.sh when PUBLIC_KEY is set.
# jq is load-bearing: start_marimo.sh uses it to URL-encode the access
# token for the proxy URL printed to the pod logs (and it remains a
# general-purpose interactive tool).
RUN apt-get update --yes && \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        ca-certificates \
        git \
        curl \
        wget \
        sudo \
        jq \
        tmux \
        nodejs \
        openssh-server \
        unzip \
    && if [ "${VARIANT}" = "gpu" ]; then \
        DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends nvtop && \
        rm -f /cuda-keyring_1.1-1_all.deb; \
    fi \
    && rm -rf /var/lib/apt/lists/*

# ── uv ───────────────────────────────────────────────────────────────────────
# Copy the uv and uvx binaries from the named uv-dist stage above. Pins an
# exact version for reproducibility and avoids an install script at build time.
COPY --from=uv-dist /uv /uvx /usr/local/bin/

# ── GitHub CLI ───────────────────────────────────────────────────────────────
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=v2.96.0
ARG GH_SHA256=83d5c2ccad5498f58bf6368acb1ab32588cf43ab3a4b1c301bf36328b1c8bd60
RUN curl -fsSL "https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION#v}_linux_amd64.tar.gz" \
        -o /tmp/gh.tar.gz && \
    echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c && \
    tar -xzf /tmp/gh.tar.gz -C /tmp && \
    install -m 755 "/tmp/gh_${GH_VERSION#v}_linux_amd64/bin/gh" /usr/local/bin/gh && \
    rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION#v}_linux_amd64"

# ── DuckDB CLI ───────────────────────────────────────────────────────────────
# renovate: datasource=github-releases depName=duckdb/duckdb
ARG DUCKDB_VERSION=v1.5.5
ARG DUCKDB_SHA256=08c0ca117111fcede14239d0093792352befdc174218c344d232c13279643d05
RUN curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-amd64.zip" \
        -o /tmp/duckdb.zip && \
    echo "${DUCKDB_SHA256}  /tmp/duckdb.zip" | sha256sum -c && \
    unzip /tmp/duckdb.zip duckdb -d /usr/local/bin && \
    chmod +x /usr/local/bin/duckdb && \
    rm /tmp/duckdb.zip

# ── runpodctl ────────────────────────────────────────────────────────────────
# renovate: datasource=github-releases depName=runpod/runpodctl
ARG RUNPODCTL_VERSION=v2.7.2
ARG RUNPODCTL_SHA256=acf5c49a3192b522e95cae92539fa6fcd8be8c48802aa26c7f3f2ec980ab4f5c
RUN curl -fsSL "https://github.com/runpod/runpodctl/releases/download/${RUNPODCTL_VERSION}/runpodctl-linux-amd64" \
        -o /usr/local/bin/runpodctl && \
    echo "${RUNPODCTL_SHA256}  /usr/local/bin/runpodctl" | sha256sum -c && \
    chmod +x /usr/local/bin/runpodctl

# ── runpod user ──────────────────────────────────────────────────────────────
# Passwordless sudo is scoped to apt-get/apt so users can install system
# packages from notebooks and terminals. This is an intentional tradeoff:
# apt can still run maintainer scripts as root, but removing sudo entirely
# would break the interactive development experience on Runpod pods.
RUN useradd -m -s /bin/bash runpod && \
    echo "runpod ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt" > /etc/sudoers.d/runpod && \
    chmod 0440 /etc/sudoers.d/runpod

# Create the marimo config dir; ensure the user owns their home dir. The
# workspace directory is created at runtime by start_marimo.sh so it can
# match the actual mount point (/workspace when a Runpod network volume
# is attached, or wherever MARIMO_WORKSPACE points).
RUN mkdir -p /home/runpod/.config/marimo && \
    chown -R runpod:runpod /home/runpod

# ── Runtime environment overrides ────────────────────────────────────────────
# UV: explicit path so marimo can find uv for in-notebook package installation.
# UV_PYTHON_INSTALL_DIR: shared system location for uv-managed Python
# interpreters so the same install is visible to root and the runpod user.
#
# UV_CACHE_DIR and HF_HOME are intentionally NOT baked in here — they are
# computed at runtime in start_marimo.sh (based on the workspace path and
# MARIMO_CACHE_DIR) and forwarded into the login-shell env via
# /etc/profile.d/zz-pod-env.sh. Baking a static value here would shadow
# any user override because Docker ENV wins over `${VAR:-default}` checks.
# At image build time, uv falls back to its own default (~/.cache/uv
# resolving to /home/runpod/.cache/uv for the runpod user), which is
# where the prewarmed uvx marimo cache below lands.
#
# NOTE: Docker ENV is not inherited by login shells (su -l). We write
# UV and UV_PYTHON_INSTALL_DIR to /etc/profile.d/ so they are available
# to all login shells as well.
ENV UV=/usr/local/bin/uv \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    MARIMO_VERSION=${MARIMO_VERSION}
# hadolint ignore=SC2016  # $PATH must stay literal for the profile script
RUN printf 'export UV=/usr/local/bin/uv\nexport UV_PYTHON_INSTALL_DIR=/opt/uv-python\nexport MARIMO_VERSION=%s\nexport PATH="/home/runpod/.local/bin:$PATH"\n' \
        "${MARIMO_VERSION}" > /etc/profile.d/runpod-env.sh

# ── Python ───────────────────────────────────────────────────────────────────
# uv manages CPython; no system python3 is installed. PYTHON_VERSION is
# pinned to a full patch release so successive builds of the same image tag
# resolve to the same interpreter; bump it explicitly to take patch updates.
#
# The install runs as the runpod user so uv's cache (~/.cache/uv →
# /home/runpod/.cache/uv) stays user-owned — running as root would make
# the cache unwritable for the later `uv tool install` step. The same
# location receives the prewarmed `uvx marimo` cache below, which lets
# pods opting out of persistent caches (MARIMO_CACHE_DIR=/home/runpod/.cache)
# launch marimo on the first boot without re-downloading. /opt/uv-python
# is pre-created and handed to runpod for the duration of the install,
# then made world-readable so root can still read the interpreter metadata.
RUN install -d -o runpod -g runpod /opt/uv-python && \
    su -l runpod -c "uv python install ${PYTHON_VERSION}" && \
    chmod -R a+rX /opt/uv-python

# ── Python tools ─────────────────────────────────────────────────────────────
# huggingface_hub and ty are installed as isolated uv tools for the runpod user.
# marimo itself is NOT installed as a tool — it runs via uvx in its own
# per-spec venv, which we pre-populate below so the first pod boot doesn't
# block on marimo's download + install.
RUN su -l runpod -c "uv tool install huggingface_hub==${HUGGINGFACE_HUB_VERSION} && uv tool install ty==${TY_VERSION}"

# ── Marimo uvx cache warm-up ─────────────────────────────────────────────────
# Populate uvx's tool-env cache so the
# `uvx --with 'mcp<2' marimo[mcp,lsp]==VER` launch in start_marimo.sh is a
# cache hit on first boot (saves ~1-2 minutes on a cold pod). uvx keys the
# cache on the whole requirement set, not the package spec alone, so this
# invocation must request the same set start_marimo.sh does — the `--with`
# cap included. See the comment above that invocation for why the cap
# exists and when to drop it. Users who override MARIMO_VERSION at runtime
# pay the download cost once for their new version.
RUN su -l runpod -c "uvx --with 'mcp<2' 'marimo[mcp,lsp]==${MARIMO_VERSION}' --version"

# ── Marimo config ────────────────────────────────────────────────────────────
COPY marimo.toml /home/runpod/.config/marimo/marimo.toml
RUN chown runpod:runpod /home/runpod/.config/marimo/marimo.toml

# ── Startup ──────────────────────────────────────────────────────────────────
COPY start_marimo.sh /start_marimo.sh
RUN chmod +x /start_marimo.sh

EXPOSE 2971

# /health is served 200 without authentication (verified on marimo 0.23.15),
# so the probe works identically with and without token auth — `/` answers
# with a 303 to the login page when a token is required. start-period is
# 600s because a first boot against an empty persistent cache (network
# volume) re-downloads marimo's sandbox deps before binding :2971; >6 min
# has been observed on a shared host under load (see tests/common.sh).
HEALTHCHECK --interval=30s --timeout=10s --start-period=600s --retries=3 \
    CMD curl -f http://localhost:2971/health || exit 1

# Version label is set last so release bumps of IMAGE_VERSION only invalidate
# the metadata layer, leaving the expensive apt/uv/Python layers cached.
ARG IMAGE_VERSION=dev
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"

CMD ["/start_marimo.sh"]
