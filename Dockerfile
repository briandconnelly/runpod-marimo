# ── Base image selection ─────────────────────────────────────────────────────
# GPU variant: upstream NVIDIA CUDA runtime on Ubuntu 24.04
# CPU variant: plain Ubuntu 24.04
# VARIANT is passed at build time; the matching base stage is selected below.
# renovate: datasource=docker depName=nvidia/cuda
ARG CUDA_BASE_TAG=12.9.2-runtime-ubuntu24.04
# renovate: datasource=docker depName=ubuntu
ARG UBUNTU_BASE_TAG=24.04
# renovate: datasource=docker depName=ghcr.io/astral-sh/uv
ARG UV_VERSION=0.13.7
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
ARG PYTHON_VERSION=3.13.18
# renovate: datasource=pypi depName=marimo
ARG MARIMO_VERSION=0.25.2
# renovate: datasource=pypi depName=huggingface_hub
ARG HUGGINGFACE_HUB_VERSION=2.4.0
# renovate: datasource=pypi depName=ty
ARG TY_VERSION=0.0.97

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
# libatomic1 is the one shared library the upstream Node binary (below)
# needs that the Ubuntu base image does not ship; everything else it links
# (libstdc++, libgcc_s, libm, libdl, libpthread) is already present.
RUN apt-get update --yes && \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        ca-certificates \
        git \
        curl \
        wget \
        sudo \
        jq \
        tmux \
        libatomic1 \
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
ARG GH_VERSION=v2.103.3
ARG GH_SHA256=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
RUN curl -fsSL "https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION#v}_linux_amd64.tar.gz" \
        -o /tmp/gh.tar.gz && \
    echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c && \
    tar -xzf /tmp/gh.tar.gz -C /tmp && \
    install -m 755 "/tmp/gh_${GH_VERSION#v}_linux_amd64/bin/gh" /usr/local/bin/gh && \
    rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION#v}_linux_amd64"

# ── DuckDB CLI ───────────────────────────────────────────────────────────────
# renovate: datasource=github-releases depName=duckdb/duckdb
ARG DUCKDB_VERSION=v2.0.0
ARG DUCKDB_SHA256=c6507206baf7793c6013dbd82368469a45f20dc0e17a6f92f204602f652ed2bc
RUN curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb-cli-linux-amd64.tar.gz" \
        -o /tmp/duckdb.tar.gz && \
    echo "${DUCKDB_SHA256}  /tmp/duckdb.tar.gz" | sha256sum -c && \
    tar -xzf /tmp/duckdb.tar.gz -C /usr/local/bin duckdb && \
    chmod +x /usr/local/bin/duckdb && \
    rm /tmp/duckdb.tar.gz

# ── runpodctl ────────────────────────────────────────────────────────────────
# renovate: datasource=github-releases depName=runpod/runpodctl
ARG RUNPODCTL_VERSION=v3.0.1
ARG RUNPODCTL_SHA256=b66d11eca8cacbf18a2de6943c6e18a79ffbdc8a3c30aa13a49dc6cfc15d4239
RUN curl -fsSL "https://github.com/runpod/runpodctl/releases/download/${RUNPODCTL_VERSION}/runpodctl-linux-amd64" \
        -o /usr/local/bin/runpodctl && \
    echo "${RUNPODCTL_SHA256}  /usr/local/bin/runpodctl" | sha256sum -c && \
    chmod +x /usr/local/bin/runpodctl

# ── Node.js ──────────────────────────────────────────────────────────────────
# Node is load-bearing for the editor, not a convenience: marimo's language
# server bridge is JavaScript (marimo/_lsp/index.cjs), and every LSP backend
# it offers — ty (enabled in marimo.toml), pylsp, basedpyright, pyrefly,
# Copilot — is launched as `node index.cjs --lsp <backend>`. marimo refuses
# to start the LSP when `node` is not on PATH, and Copilot requires Node 20+.
#
# Installed from the upstream release tarball rather than Ubuntu's `nodejs`
# package because that package is Node 18, end-of-life since April 2025 and
# no longer receiving security fixes. Only the `node` binary is installed —
# no npm, npx or headers — so nothing here can install packages, and a
# notebook cannot import it. The tarball carries its LICENSE, shipped under
# /usr/share/licenses/node because this image is published publicly.
# renovate: datasource=node-version depName=node
ARG NODE_VERSION=v26.13.0
ARG NODE_SHA256=5848553868b402d3fabb5b09270649977780a390f832155721025a08b5104455
RUN curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.gz" \
        -o /tmp/node.tar.gz && \
    echo "${NODE_SHA256}  /tmp/node.tar.gz" | sha256sum -c && \
    mkdir -p /usr/share/licenses/node && \
    tar -xzf /tmp/node.tar.gz -C /usr/local/bin --strip-components=2 \
        "node-${NODE_VERSION}-linux-x64/bin/node" && \
    tar -xzf /tmp/node.tar.gz -C /usr/share/licenses/node --strip-components=1 \
        "node-${NODE_VERSION}-linux-x64/LICENSE" && \
    rm /tmp/node.tar.gz && \
    chmod 755 /usr/local/bin/node && \
    node --version

# ── Coding agents: pi and opencode ───────────────────────────────────────────
# Both ship as pinned, checksum-verified standalone Linux builds, like every
# other tool above. The npm route is not an option: the image ships only the
# `node` binary (no npm), and both projects publish Bun-compiled binaries
# that need no Node at all, so npm would add an unpinned toolchain for
# nothing.
#
# Neither binary is a Python package; nothing here is importable from a
# notebook, so the no-domain-packages rule is untouched. Both agents scan
# ~/.agents/skills, so the marimo-pair skill linked below is discovered by
# either one with no further wiring.
#
# Neither release tarball carries a LICENSE (both projects are MIT), so each
# upstream LICENSE is fetched from the same pinned tag as a second
# checksum-verified download. scripts/sync-checksums.sh pairs a
# *_LICENSE_SHA256 ARG with the tool's own *_VERSION ARG for that purpose.

# pi (https://pi.dev) resolves themes, assets and a wasm module relative to
# its real path, so the whole extracted tree stays together under /opt/pi and
# a tiny launcher goes on PATH — the same shape as pi's own installer, which
# execs the release binary from a managed directory.
# renovate: datasource=github-releases depName=earendil-works/pi
ARG PI_VERSION=v1.5.0
ARG PI_SHA256=df870ba0e344cb7b3358d8d8f19397b8b8d225a8669784736ad68a5c2169d53b
ARG PI_LICENSE_SHA256=0457f5bcec3b3b211605dfb5d1a49042fd638f3686a410fe099c24a25af13c48
# hadolint ignore=SC2016  # the "$@" must reach the launcher unexpanded
RUN curl -fsSL "https://github.com/earendil-works/pi/releases/download/${PI_VERSION}/pi-linux-x64.tar.gz" \
        -o /tmp/pi.tar.gz && \
    echo "${PI_SHA256}  /tmp/pi.tar.gz" | sha256sum -c && \
    tar -xzf /tmp/pi.tar.gz -C /opt && \
    rm /tmp/pi.tar.gz && \
    test -x /opt/pi/pi && \
    mkdir -p /usr/share/licenses/pi && \
    curl -fsSL "https://raw.githubusercontent.com/earendil-works/pi/${PI_VERSION}/LICENSE" \
        -o /usr/share/licenses/pi/LICENSE && \
    echo "${PI_LICENSE_SHA256}  /usr/share/licenses/pi/LICENSE" | sha256sum -c && \
    printf '#!/bin/sh\nexec /opt/pi/pi "$@"\n' > /usr/local/bin/pi && \
    chmod 755 /usr/local/bin/pi && \
    chmod -R a+rX /opt/pi /usr/share/licenses/pi

# opencode (https://opencode.ai) is a single self-contained binary.
# renovate: datasource=github-releases depName=anomalyco/opencode
ARG OPENCODE_VERSION=v2.2.5
ARG OPENCODE_SHA256=09f44302c10fd036912f59c81fd1aef5df45dd06f649197f9dfc9bbe2a79614e
ARG OPENCODE_LICENSE_SHA256=625f0f619133f89bbbb2abe37369613dfa1885eba1e50d02170deb62bb42cb6b
RUN curl -fsSL "https://github.com/anomalyco/opencode/releases/download/${OPENCODE_VERSION}/opencode-linux-x64.tar.gz" \
        -o /tmp/opencode.tar.gz && \
    echo "${OPENCODE_SHA256}  /tmp/opencode.tar.gz" | sha256sum -c && \
    tar -xzf /tmp/opencode.tar.gz -C /usr/local/bin opencode && \
    chmod 755 /usr/local/bin/opencode && \
    rm /tmp/opencode.tar.gz && \
    mkdir -p /usr/share/licenses/opencode && \
    curl -fsSL "https://raw.githubusercontent.com/anomalyco/opencode/${OPENCODE_VERSION}/LICENSE" \
        -o /usr/share/licenses/opencode/LICENSE && \
    echo "${OPENCODE_LICENSE_SHA256}  /usr/share/licenses/opencode/LICENSE" | sha256sum -c && \
    chmod -R a+rX /usr/share/licenses/opencode

# ── marimo-pair skill ────────────────────────────────────────────────────────
# The marimo-pair agent skill (https://github.com/marimo-team/marimo-pair)
# lets a coding agent drive the live marimo kernel instead of editing the
# notebook file behind the kernel's back. It is markdown plus bash — its only
# runtime deps are bash, curl and jq, all installed above — so it does not
# touch the no-domain-packages rule: nothing here is importable from a
# notebook.
#
# Upstream documents `npx skills add` or the Claude Code plugin marketplace.
# Neither is usable here: the image ships no npm/npx, and an unpinned
# network install at build time would be the only unverified download in
# this image. So the release tarball is pinned and checksum-verified like
# every other tool above. The repo publishes no release assets, hence the
# generated tag archive and `datasource=github-tags`.
#
# Only skills/marimo-pair is extracted; the sibling retro-marimo-pair skill
# is an upstream-feedback command with no use on a pod. LICENSE lives at the
# repo root, outside the extracted subtree, so it is unpacked separately —
# this image is published publicly and ships Apache-2.0 code.
# renovate: datasource=github-tags depName=marimo-team/marimo-pair
ARG MARIMO_PAIR_VERSION=v0.0.20
ARG MARIMO_PAIR_SHA256=7627a0396e06527f1fd0d55e0fe1975a554440eaf960eba91fa1ab3ceeda40e8
RUN curl -fsSL "https://github.com/marimo-team/marimo-pair/archive/refs/tags/${MARIMO_PAIR_VERSION}.tar.gz" \
        -o /tmp/marimo-pair.tar.gz && \
    echo "${MARIMO_PAIR_SHA256}  /tmp/marimo-pair.tar.gz" | sha256sum -c && \
    mkdir -p /opt/agent-skills /usr/share/licenses/marimo-pair && \
    tar -xzf /tmp/marimo-pair.tar.gz -C /opt/agent-skills --strip-components=2 \
        "marimo-pair-${MARIMO_PAIR_VERSION#v}/skills/marimo-pair" && \
    tar -xzf /tmp/marimo-pair.tar.gz -C /usr/share/licenses/marimo-pair --strip-components=1 \
        "marimo-pair-${MARIMO_PAIR_VERSION#v}/LICENSE" && \
    rm /tmp/marimo-pair.tar.gz && \
    printf 'marimo-pair %s\nhttps://github.com/marimo-team/marimo-pair\nApache-2.0; license at /usr/share/licenses/marimo-pair/LICENSE\n' \
        "${MARIMO_PAIR_VERSION}" > /opt/agent-skills/marimo-pair/PROVENANCE && \
    chmod -R a+rX /opt/agent-skills /usr/share/licenses/marimo-pair

# ── runpod user ──────────────────────────────────────────────────────────────
# marimo runs as `runpod` rather than root. Be clear about what that buys:
# it is hygiene, not a security boundary. The passwordless sudo below is
# scoped to apt-get/apt so users can install system packages from the
# marimo terminal, and apt is root-equivalent by design — maintainer scripts
# run as root, and `sudo apt-get -o APT::Update::Pre-Invoke=<cmd> update`
# runs any command as root in one line. So anything running as `runpod`
# (every notebook cell) can become root whenever it wants to.
#
# That is acceptable here because this image's trust model already grants
# the same thing: it sets no USER, so the Runpod console, SSH and `docker
# exec` all land as root, and the pod is single-tenant. What the separate
# user does provide is unprivileged defaults — files created by notebooks
# are not root-owned, a stray `rm -rf` inside a cell cannot take out /usr,
# and the HOME-relative caches (uv tool envs, HF token) live in a
# predictable per-user place. The 0600 token file and 0640 pod-env file
# are protection against accidental reads, not against a hostile notebook.
# The READMEs state this plainly; do not describe `runpod` as a sandbox.
RUN useradd -m -s /bin/bash runpod && \
    echo "runpod ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt" > /etc/sudoers.d/runpod && \
    chmod 0440 /etc/sudoers.d/runpod

# Create the marimo config dir; ensure the user owns their home dir. The
# workspace directory is created at runtime by start_marimo.sh so it can
# match the actual mount point (/workspace when a Runpod network volume
# is attached, or wherever MARIMO_WORKSPACE points).
#
# The marimo-pair skill is linked into the per-user skill directories that
# agent harnesses scan, for BOTH identities a user can land as. This image
# sets no USER, so `docker exec` and the Runpod console give a root shell,
# and start_marimo.sh authorizes SSH keys into /root/.ssh — only marimo
# itself runs as runpod. Linking under /home/runpod alone would leave the
# skill undiscoverable for the shell most users actually get.
#
# `.claude/skills` is Claude Code's user-global location; `.agents/skills`
# is the cross-client Agent Skills convention. Both harnesses follow
# symlinks, so one canonical copy under /opt serves every link.
RUN mkdir -p /home/runpod/.config/marimo && \
    for home in /root /home/runpod; do \
        mkdir -p "${home}/.claude/skills" "${home}/.agents/skills" && \
        ln -sfn /opt/agent-skills/marimo-pair "${home}/.claude/skills/marimo-pair" && \
        ln -sfn /opt/agent-skills/marimo-pair "${home}/.agents/skills/marimo-pair"; \
    done && \
    chown -Rh runpod:runpod /home/runpod

# ── Non-login shell environment ──────────────────────────────────────────────
# /etc/profile.d is sourced only by LOGIN shells. The Runpod SSH proxy and
# `docker exec` both exec bash directly without one — the MOTD removed in
# 0.6.0 hit exactly this failure — so an agent launched from the shell a
# user actually gets would not see MARIMO_TOKEN and could not authenticate
# against :2971.
#
# The value is read from the token file at shell start rather than baked in
# here, so it cannot go stale across a pod restart, and the token file's
# presence is treated as authoritative: absent (auth disabled, where
# start_marimo.sh removes it) means any inbound MARIMO_TOKEN inherited from
# the container environment is cleared rather than left pointing at a server
# that accepts no token.
# Ubuntu's stock .bashrc returns early for non-interactive shells, so
# this covers interactive ones; a scripted `docker exec bash -c` should read
# the token file directly, as the READMEs document.
# hadolint ignore=SC2016  # the $(cat ...) must reach .bashrc unexpanded
RUN printf '%s\n' \
        '' \
        '# Resolved marimo access token, for marimo-pair and other agent tooling.' \
        '# Read here because /etc/profile.d reaches only login shells.' \
        '# Authoritative in both directions: an inbound MARIMO_TOKEN pod env' \
        '# var is inherited straight from the container environment, so it' \
        '# must be cleared when the server is running without auth.' \
        'if [ -r /home/runpod/.config/marimo/token ]; then' \
        '    MARIMO_TOKEN=$(cat /home/runpod/.config/marimo/token) && export MARIMO_TOKEN' \
        'else' \
        '    unset MARIMO_TOKEN' \
        'fi' \
    | tee -a /root/.bashrc >> /home/runpod/.bashrc

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
# Populate uvx's tool-env cache so the `uvx marimo[mcp,lsp]==VER` launch in
# start_marimo.sh is a cache hit on first boot (saves ~1-2 minutes on a cold
# pod). uvx keys the cache on the whole requirement set, not the package spec
# alone, so this invocation must request the same set start_marimo.sh does.
# Users who override MARIMO_VERSION at runtime pay the download cost once for
# their new version.
RUN su -l runpod -c "uvx 'marimo[mcp,lsp]==${MARIMO_VERSION}' --version"

# ── Marimo config ────────────────────────────────────────────────────────────
COPY marimo.toml /home/runpod/.config/marimo/marimo.toml
RUN chown runpod:runpod /home/runpod/.config/marimo/marimo.toml

# ── Startup ──────────────────────────────────────────────────────────────────
COPY start_marimo.sh /start_marimo.sh
RUN chmod +x /start_marimo.sh

EXPOSE 2971

# /health is served 200 without authentication (verified on marimo 0.24.2),
# so the probe works identically with and without token auth — `/` answers
# with a 303 to the login page when a token is required. start-period is
# 600s because a first boot against an empty persistent cache (network
# volume) re-downloads marimo's sandbox deps before binding :2971; >6 min
# has been observed on a shared host under load (see tests/common.sh).
#
# JSON (exec) notation, so hadolint's DL3025 is satisfied without an ignore.
# The probe still needs a shell for the `||`, so one is named explicitly;
# that makes it /bin/sh rather than the bash named by the SHELL instruction
# above, which is immaterial here — no bashism, no pipeline. `|| exit 1`
# normalises curl's varied failure codes (7 refused, 22 HTTP >= 400, 28
# timeout) to the 1 that Docker documents as "unhealthy".
HEALTHCHECK --interval=30s --timeout=10s --start-period=600s --retries=3 \
    CMD ["/bin/sh", "-c", "curl -f http://localhost:2971/health || exit 1"]

# Version label is set last so release bumps of IMAGE_VERSION only invalidate
# the metadata layer, leaving the expensive apt/uv/Python layers cached.
ARG IMAGE_VERSION=dev
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"

CMD ["/start_marimo.sh"]
