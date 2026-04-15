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
        python3-pip \
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

# Create the default marimo workspace and ensure the user owns their home dir
RUN mkdir -p /home/runpod/workspace && \
    chown -R runpod:runpod /home/runpod

# ── Runtime environment overrides ────────────────────────────────────────────
# The base image sets UV_CACHE_DIR and HF_HOME to /workspace paths that are
# root-owned and not writable by the runpod user when no volume is mounted.
# Override both to user-owned locations so they work regardless of whether
# /workspace is mounted. Also set UV so marimo detects uv as its package
# manager instead of falling back to pip.
#
# NOTE: Docker ENV is not inherited by login shells (su -l). We write these
# to /etc/profile.d/ so they are available to all login shells as well.
ENV UV=/usr/local/bin/uv
ENV UV_CACHE_DIR=/home/runpod/.cache/uv
ENV HF_HOME=/home/runpod/.cache/huggingface
RUN printf 'export UV=/usr/local/bin/uv\nexport UV_CACHE_DIR=/home/runpod/.cache/uv\nexport HF_HOME=/home/runpod/.cache/huggingface\n' \
        > /etc/profile.d/runpod-env.sh

# ── Python tools (system-wide) ───────────────────────────────────────────────
# pip bootstraps the install; marimo[recommended] pulls in uv as a dependency,
# so no separate uv installation step is needed.
RUN pip install --break-system-packages "marimo[recommended]" huggingface_hub

# ── Startup ──────────────────────────────────────────────────────────────────
COPY start_marimo.sh /start_marimo.sh
RUN chmod +x /start_marimo.sh

CMD ["/start_marimo.sh"]
