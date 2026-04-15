# Runpod Marimo Dev Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Docker image for Runpod that launches a marimo editor on port 2971 with a curated set of AI/ML development tools pre-installed.

**Architecture:** A single `Dockerfile` builds on `runpod/base:1.0.3-cuda1300-ubuntu2404`, installs system and CLI tools, creates a `runpod` user with passwordless sudo, installs marimo and huggingface-cli as uv tools, and launches marimo via a startup script. A companion `start_marimo.sh` chains Runpod's base infrastructure init with the marimo editor process.

**Tech Stack:** Docker, Ubuntu 24.04 (CUDA 13.0), uv, marimo, GitHub CLI, runpodctl, huggingface_hub

---

### Task 1: Inspect the base image and clean up the repo

**Files:**
- Delete: `requirements.txt`
- Delete: `main.py`

- [ ] **Step 1: Pull the base image and inspect its ENTRYPOINT and CMD**

```bash
docker pull runpod/base:1.0.3-cuda1300-ubuntu2404
docker inspect runpod/base:1.0.3-cuda1300-ubuntu2404 \
  | jq '.[0].Config | {Entrypoint, Cmd}'
```

**Confirmed result (already inspected):**
```json
{
  "Entrypoint": ["/opt/nvidia/nvidia_entrypoint.sh"],
  "Cmd": ["/start.sh"]
}
```

The base image has NVIDIA's GPU init script as its ENTRYPOINT and Runpod's `/start.sh` as CMD.
Docker runs: `nvidia_entrypoint.sh /start.sh` by default.
By setting `CMD ["/start_marimo.sh"]` in our Dockerfile, Docker will run: `nvidia_entrypoint.sh /start_marimo.sh`.
This preserves NVIDIA GPU initialization while replacing the startup command.
Do NOT use `ENTRYPOINT` in our Dockerfile — that would override NVIDIA's init.
`start_marimo.sh` must call `/start.sh` internally (Runpod SSH/env init), then exec marimo.

- [ ] **Step 2: Remove the empty placeholder files**

```bash
rm /path/to/repo/requirements.txt /path/to/repo/main.py
```

- [ ] **Step 3: Commit the cleanup**

```bash
git init  # only if not already a git repo
git add -A
git commit -m "chore: remove unused placeholder files"
```

---

### Task 2: Create the startup script

**Files:**
- Create: `start_marimo.sh`

- [ ] **Step 1: Write `start_marimo.sh`**

```bash
#!/bin/bash
set -e

# Start Runpod base infrastructure (SSH, environment setup, etc.) in the background.
# This preserves SSH access and Runpod-specific environment initialization.
if [ -f /start.sh ]; then
    bash /start.sh &
    sleep 2
fi

# Launch marimo editor as the runpod user.
# --host 0.0.0.0  : bind to all interfaces so Runpod's proxy can reach it
# --port 2971     : marimo's default port (exposed in the Runpod template config)
# --no-token      : disable marimo's token auth; Runpod's proxy handles auth
# /home/runpod/workspace : open the workspace directory in the file browser
exec su -l runpod -c "/home/runpod/.local/bin/marimo edit \
    --host 0.0.0.0 \
    --port 2971 \
    --no-token \
    /home/runpod/workspace"
```

Write this to `start_marimo.sh` in the repo root.

- [ ] **Step 2: Verify the script has the correct shebang and is not Windows line-endings**

```bash
head -1 start_marimo.sh
file start_marimo.sh
```

Expected:
```
#!/bin/bash
start_marimo.sh: ASCII text
```

- [ ] **Step 3: Commit**

```bash
git add start_marimo.sh
git commit -m "feat: add marimo startup script"
```

---

### Task 3: Write the Dockerfile

**Files:**
- Modify: `Dockerfile`

Replace the entire existing `Dockerfile` contents with the following. Each `RUN` block is a separate layer comment — do not collapse into one giant RUN for readability and cache efficiency.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
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
```

- [ ] **Step 2: Verify the Dockerfile parses without errors (no build yet)**

```bash
docker buildx build --check .
```

Expected: exits cleanly with no errors. If `--check` is not available on your Docker version, skip to Step 3.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: write Runpod marimo image Dockerfile"
```

---

### Task 4: Build the image and verify

**Files:** none (verification only)

- [ ] **Step 1: Build the image**

```bash
docker build -t runpod-marimo:dev .
```

Expected: build completes without errors. Each layer should succeed. Watch for:
- `apt-get install` failures (package name typos, repo issues)
- `runpodctl` download failures (GitHub API rate limits — retry if needed)
- `uv tool install` failures (network or package resolution errors)

- [ ] **Step 2: Verify system tools are present**

```bash
docker run --rm runpod-marimo:dev bash -c "
    echo '=== git ===' && git --version &&
    echo '=== gh ===' && gh --version &&
    echo '=== jq ===' && jq --version &&
    echo '=== tmux ===' && tmux -V &&
    echo '=== nvtop ===' && nvtop --version &&
    echo '=== runpodctl ===' && runpodctl version &&
    echo '=== uv ===' && uv --version
"
```

Expected: all tools print their version strings without errors.

- [ ] **Step 3: Verify uv tools are installed for the runpod user**

```bash
docker run --rm runpod-marimo:dev su -l runpod -c "
    echo '=== marimo ===' && /home/runpod/.local/bin/marimo --version &&
    echo '=== huggingface-cli ===' && /home/runpod/.local/bin/huggingface-cli --help | head -3
"
```

Expected: marimo prints its version, huggingface-cli prints its help header.

- [ ] **Step 4: Verify marimo starts and listens on port 2971**

```bash
docker run --rm -d --name marimo-test -p 2971:2971 runpod-marimo:dev
sleep 5
curl -sf http://localhost:2971 | head -20
docker stop marimo-test
```

Expected: curl returns HTML content (the marimo editor page). If it returns a connection refused, check `docker logs marimo-test` for startup errors.

- [ ] **Step 5: Verify the runpod user has passwordless sudo**

```bash
docker run --rm runpod-marimo:dev su -l runpod -c "sudo id"
```

Expected: `uid=0(root) gid=0(root) groups=0(root)` — confirms sudo works without a password prompt.

- [ ] **Step 6: Commit (tag the verified image)**

```bash
git tag v0.1.0
git commit --allow-empty -m "chore: verified v0.1.0 build passes all smoke tests"
```

---

### Task 5: Push image and configure Runpod template

**Files:** none (external systems)

- [ ] **Step 1: Tag and push to your container registry**

Replace `<registry>` and `<username>` with your actual registry (e.g., Docker Hub: `docker.io/username`).

```bash
docker tag runpod-marimo:dev <registry>/runpod-marimo:latest
docker push <registry>/runpod-marimo:latest
```

- [ ] **Step 2: Configure the Runpod template**

In the Runpod UI (https://www.runpod.io/console/user/templates), create a new template with:

| Field | Value |
|-------|-------|
| Template name | `Marimo Dev` (or your preference) |
| Container image | `<registry>/runpod-marimo:latest` |
| Container start command | *(leave blank)* |
| Expose HTTP ports | `2971` |
| Volume mount path | `/home/runpod/workspace` |

- [ ] **Step 3: Launch a test pod from the template and verify marimo is reachable**

Launch a pod from the template in the Runpod console.
Once running, click the `2971` port link in the Runpod UI.
Expected: marimo editor opens in the browser showing the `/home/runpod/workspace` file browser.
