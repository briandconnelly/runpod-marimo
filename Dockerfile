FROM runpod/base:1.0.3-cuda1300-ubuntu2404

# Ensure Python output is immediately flushed to logs
ENV PYTHONUNBUFFERED=1

# ── System packages ──────────────────────────────────────────────────────────
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
# Resolves the latest release tag at build time via the GitHub API.
# Requires jq (installed above) and a network connection.
RUN LATEST=$(curl -fsSL https://api.github.com/repos/runpod/runpodctl/releases/latest \
        | jq -r '.tag_name') && \
    curl -fsSL "https://github.com/runpod/runpodctl/releases/download/${LATEST}/runpodctl-linux-amd64" \
        -o /usr/local/bin/runpodctl && \
    chmod +x /usr/local/bin/runpodctl

# ── uv ───────────────────────────────────────────────────────────────────────
# Installs uv and uvx binaries to /usr/local/bin (system-wide).
RUN curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin sh

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
USER runpod
RUN uv tool install marimo && \
    uv tool install "huggingface_hub[cli]"
USER root

# ── Startup ──────────────────────────────────────────────────────────────────
COPY start_marimo.sh /start_marimo.sh
RUN chmod +x /start_marimo.sh

CMD ["/start_marimo.sh"]
