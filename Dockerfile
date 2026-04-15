FROM runpod/base:1.0.3-cuda1300-ubuntu2404

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

# ── uv ───────────────────────────────────────────────────────────────────────
# Installs uv and uvx binaries to /usr/local/bin (system-wide).
ARG UV_VERSION=0.11.6
RUN curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin UV_VERSION=${UV_VERSION} sh

# ── runpod user ──────────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash runpod && \
    echo "runpod ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runpod && \
    chmod 0440 /etc/sudoers.d/runpod

# Create the default marimo workspace and ensure the user owns their home dir
RUN mkdir -p /home/runpod/workspace && \
    chown -R runpod:runpod /home/runpod

# ── uv tools (installed as runpod user) ──────────────────────────────────────
# marimo     → /home/runpod/.local/bin/marimo
# huggingface_hub → /home/runpod/.local/bin/huggingface-cli
#
# Override UV_CACHE_DIR: the base image sets it to /workspace/.cache/uv/ which
# is root-owned and not writable by the runpod user during the build.
USER runpod
RUN UV_CACHE_DIR=/home/runpod/.cache/uv uv tool install marimo && \
    UV_CACHE_DIR=/home/runpod/.cache/uv uv tool install "huggingface_hub[cli]"
USER root

# ── Startup ──────────────────────────────────────────────────────────────────
COPY start_marimo.sh /start_marimo.sh
RUN chmod +x /start_marimo.sh

CMD ["/start_marimo.sh"]
