# ── Base image selection ─────────────────────────────────────────────────────
# GPU variant: upstream NVIDIA CUDA runtime on Ubuntu 24.04
# CPU variant: plain Ubuntu 24.04
# VARIANT is passed at build time; the matching base stage is selected below.
# renovate: datasource=docker depName=nvidia/cuda
ARG CUDA_BASE_TAG=12.5.1-runtime-ubuntu24.04
# renovate: datasource=docker depName=ubuntu
ARG UBUNTU_BASE_TAG=24.04
# renovate: datasource=docker depName=ghcr.io/astral-sh/uv
ARG UV_VERSION=0.11.7
ARG VARIANT=gpu

# Named stage for the uv binary distribution. A named stage is used rather
# than `COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION}` because BuildKit does
# not reliably expand ARGs in the image reference of a COPY --from.
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-dist

FROM nvidia/cuda:${CUDA_BASE_TAG} AS base-gpu
FROM ubuntu:${UBUNTU_BASE_TAG} AS base-cpu
FROM base-${VARIANT}

# Re-declare ARGs that need to be visible after the final FROM.
# IMAGE_VERSION is intentionally declared and consumed at the bottom of the
# stage so a version bump only invalidates the final LABEL layer instead of
# everything downstream of it.
ARG VARIANT
ARG IMAGE_DESCRIPTION="Marimo notebook server for Runpod GPU pods"
# renovate: datasource=python-version depName=python
ARG PYTHON_VERSION=3.13.13
# renovate: datasource=pypi depName=marimo
ARG MARIMO_VERSION=0.23.1
# renovate: datasource=pypi depName=huggingface_hub
ARG HUGGINGFACE_HUB_VERSION=1.11.0
# renovate: datasource=pypi depName=ty
ARG TY_VERSION=0.0.31

LABEL org.opencontainers.image.title="runpod-marimo" \
      org.opencontainers.image.description="${IMAGE_DESCRIPTION}" \
      org.opencontainers.image.authors="brian.connelly@runpod.io"

# Ensure Python output is immediately flushed to logs
ENV PYTHONUNBUFFERED=1

# ── System packages ──────────────────────────────────────────────────────────
# ca-certificates + curl are required for the tool downloads below.
# openssh-server provides sshd and the /etc/init.d/ssh script used by
# start_marimo.sh when PUBLIC_KEY is set.
# jq is retained as a general-purpose interactive tool in the container.
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
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update --yes && \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes gh && \
    rm -rf /var/lib/apt/lists/*

# ── DuckDB CLI ───────────────────────────────────────────────────────────────
# renovate: datasource=github-releases depName=duckdb/duckdb
ARG DUCKDB_VERSION=v1.5.2
ARG DUCKDB_SHA256=fc9145affabca627431e73ddaf6b8117e5c192692480c13886f227be202d5d15
RUN curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-amd64.zip" \
        -o /tmp/duckdb.zip && \
    echo "${DUCKDB_SHA256}  /tmp/duckdb.zip" | sha256sum -c && \
    unzip /tmp/duckdb.zip duckdb -d /usr/local/bin && \
    chmod +x /usr/local/bin/duckdb && \
    rm /tmp/duckdb.zip

# ── runpodctl ────────────────────────────────────────────────────────────────
# renovate: datasource=github-releases depName=runpod/runpodctl
ARG RUNPODCTL_VERSION=v2.1.9
ARG RUNPODCTL_SHA256=777c0475f9966b341af2c4cc17a3c730a2a2655aa0e14c86bb9929cca89846a5
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
RUN printf 'export UV=/usr/local/bin/uv\nexport UV_PYTHON_INSTALL_DIR=/opt/uv-python\nexport MARIMO_VERSION=%s\nexport PATH="/home/runpod/.local/bin:$PATH"\n' \
        "${MARIMO_VERSION}" > /etc/profile.d/runpod-env.sh

# ── Python ───────────────────────────────────────────────────────────────────
# uv manages CPython; no system python3 is installed. PYTHON_VERSION is
# pinned to a full patch release so successive builds of the same image tag
# resolve to the same interpreter; bump it explicitly to take patch updates.
#
# The install runs as the runpod user so uv's cache (UV_CACHE_DIR under
# /home/runpod) stays user-owned — running as root would make the cache
# unwritable for the later `uv tool install` step. /opt/uv-python is
# pre-created and handed to runpod for the duration of the install, then
# made world-readable so root can still read the interpreter metadata.
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
# Populate uvx's per-spec tool-env cache so `uvx marimo[mcp,lsp]==VER` in
# start_marimo.sh is a cache hit on first boot (saves ~1-2 minutes on a cold
# pod). The cache key is the exact spec string, so this invocation must
# match what start_marimo.sh uses. Users who override MARIMO_VERSION at
# runtime pay the download cost once for their new version.
RUN su -l runpod -c "uvx 'marimo[mcp,lsp]==${MARIMO_VERSION}' --version"

# ── Marimo config ────────────────────────────────────────────────────────────
COPY marimo.toml /home/runpod/.config/marimo/marimo.toml
RUN chown runpod:runpod /home/runpod/.config/marimo/marimo.toml

# ── Startup ──────────────────────────────────────────────────────────────────
COPY start_marimo.sh /start_marimo.sh
RUN chmod +x /start_marimo.sh

EXPOSE 2971

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:2971/ || exit 1

# Version label is set last so release bumps of IMAGE_VERSION only invalidate
# the metadata layer, leaving the expensive apt/uv/Python layers cached.
ARG IMAGE_VERSION=dev
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"

CMD ["/start_marimo.sh"]
