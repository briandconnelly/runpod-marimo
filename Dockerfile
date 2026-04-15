FROM runpod/base:1.0.3-cuda1300-ubuntu2404

ARG IMAGE_VERSION=dev

LABEL org.opencontainers.image.title="runpod-marimo" \
      org.opencontainers.image.description="Marimo notebook server for Runpod GPU pods" \
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
        nvtop \
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

# ── runpodctl ────────────────────────────────────────────────────────────────
ARG RUNPODCTL_VERSION=v2.1.9
RUN curl -fsSL "https://github.com/runpod/runpodctl/releases/download/${RUNPODCTL_VERSION}/runpodctl-linux-amd64" \
        -o /usr/local/bin/runpodctl && \
    chmod +x /usr/local/bin/runpodctl

# ── runpod user ──────────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash runpod && \
    echo "runpod ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runpod && \
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
    HF_HOME=/home/runpod/.cache/huggingface
RUN printf 'export UV=/usr/bin/uv\nexport UV_CACHE_DIR=/home/runpod/.cache/uv\nexport HF_HOME=/home/runpod/.cache/huggingface\nexport PATH="/home/runpod/.local/bin:$PATH"\n' \
        > /etc/profile.d/runpod-env.sh

# ── Python tools ─────────────────────────────────────────────────────────────
# huggingface_hub is installed as an isolated uv tool for the runpod user.
# marimo itself is NOT pre-installed; it is launched via uvx so it runs in
# its own clean virtual environment (first launch populates the cache).
RUN su -l runpod -c "uv tool install huggingface_hub"

# ── Marimo config ────────────────────────────────────────────────────────────
COPY marimo.toml /home/runpod/.config/marimo/marimo.toml
RUN chown runpod:runpod /home/runpod/.config/marimo/marimo.toml

# ── Startup ──────────────────────────────────────────────────────────────────
COPY start_marimo.sh /start_marimo.sh
RUN chmod +x /start_marimo.sh

EXPOSE 2971

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:2971/ || exit 1

CMD ["/start_marimo.sh"]
