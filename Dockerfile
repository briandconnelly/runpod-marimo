ARG BASE_IMAGE=runpod/base:1.0.3-cuda1300-ubuntu2404
FROM ${BASE_IMAGE}

ARG IMAGE_VERSION=dev
ARG VARIANT=gpu
ARG IMAGE_DESCRIPTION="Marimo notebook server for Runpod GPU pods"
ARG MARIMO_VERSION=0.23.1
ARG HUGGINGFACE_HUB_VERSION=1.10.2
ARG TY_VERSION=0.0.31

LABEL org.opencontainers.image.title="runpod-marimo" \
      org.opencontainers.image.description="${IMAGE_DESCRIPTION}" \
      org.opencontainers.image.authors="brian.connelly@runpod.io" \
      org.opencontainers.image.version="${IMAGE_VERSION}"

# Ensure Python output is immediately flushed to logs
ENV PYTHONUNBUFFERED=1

# ── System packages ──────────────────────────────────────────────────────────
# jq is retained as a general-purpose interactive tool in the container
RUN apt-get update --yes && \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        git \
        curl \
        wget \
        sudo \
        jq \
        tmux \
        nodejs \
        unzip \
    && if [ "${VARIANT}" = "gpu" ]; then \
        DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends nvtop; \
    fi \
    && rm -rf /var/lib/apt/lists/*

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
ARG DUCKDB_VERSION=v1.5.2
ARG DUCKDB_SHA256=fc9145affabca627431e73ddaf6b8117e5c192692480c13886f227be202d5d15
RUN curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-amd64.zip" \
        -o /tmp/duckdb.zip && \
    echo "${DUCKDB_SHA256}  /tmp/duckdb.zip" | sha256sum -c && \
    unzip /tmp/duckdb.zip duckdb -d /usr/local/bin && \
    chmod +x /usr/local/bin/duckdb && \
    rm /tmp/duckdb.zip

# ── runpodctl ────────────────────────────────────────────────────────────────
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

# Create the default marimo workspace and config dir; ensure the user owns their home dir
RUN mkdir -p /home/runpod/workspace /home/runpod/.config/marimo && \
    chown -R runpod:runpod /home/runpod

# ── Runtime environment overrides ────────────────────────────────────────────
# UV: explicit path so marimo can find uv for in-notebook package installation.
# UV_CACHE_DIR / HF_HOME: the base image sets these to /workspace paths that
# are root-owned and not writable by the runpod user when no volume is mounted.
# Override both to user-owned locations so they work regardless of whether
# /workspace is mounted.
#
# NOTE: Docker ENV is not inherited by login shells (su -l). We write these
# to /etc/profile.d/ so they are available to all login shells as well.
ENV UV=/usr/bin/uv \
    UV_CACHE_DIR=/home/runpod/.cache/uv \
    HF_HOME=/home/runpod/.cache/huggingface \
    MARIMO_VERSION=${MARIMO_VERSION}
RUN printf 'export UV=/usr/bin/uv\nexport UV_CACHE_DIR=/home/runpod/.cache/uv\nexport HF_HOME=/home/runpod/.cache/huggingface\nexport MARIMO_VERSION=%s\nexport PATH="/home/runpod/.local/bin:$PATH"\n' \
        "${MARIMO_VERSION}" > /etc/profile.d/runpod-env.sh

# ── Python tools ─────────────────────────────────────────────────────────────
# huggingface_hub is installed as an isolated uv tool for the runpod user.
# marimo itself is NOT pre-installed; it is launched via uvx so it runs in
# its own clean virtual environment (first launch populates the cache).
RUN su -l runpod -c "uv tool install huggingface_hub==${HUGGINGFACE_HUB_VERSION} && uv tool install ty==${TY_VERSION}"

# ── Marimo config ────────────────────────────────────────────────────────────
COPY marimo.toml /home/runpod/.config/marimo/marimo.toml
COPY runpod.css /home/runpod/.config/marimo/runpod.css
RUN chown -R runpod:runpod /home/runpod/.config/marimo

# ── Startup ──────────────────────────────────────────────────────────────────
COPY start_marimo.sh /start_marimo.sh
RUN chmod +x /start_marimo.sh

EXPOSE 2971

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:2971/ || exit 1

CMD ["/start_marimo.sh"]
