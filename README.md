# runpod-marimo

A Docker image that runs [marimo](https://marimo.io) as a notebook server on [Runpod](https://runpod.io) GPU and CPU pods.
Marimo is served on port **2971** and is accessible via Runpod's web proxy.

## Variants

The image is published in two variants from a single Dockerfile:

| Variant | Base image | Tag examples |
|---|---|---|
| GPU | `nvidia/cuda:*-runtime-ubuntu24.04` | `0.10.2`, `0.10`, `0.10.2-gpu`, `0.10-gpu` |
| CPU | `ubuntu:24.04` | `0.10.2-cpu`, `0.10-cpu` |

Bare version tags (without a `-gpu` or `-cpu` suffix) resolve to the GPU variant.

The GPU variant requires an NVIDIA driver supporting CUDA 12.9 (Linux driver >= 575), or a 535/550/560/565/570-series driver via CUDA forward compatibility.
On an older driver the container refuses to start with `unsatisfied condition: cuda>=12.9`.

The [GPU](README-gpu.md) and [CPU](README-cpu.md) variants each have a dedicated README tailored for Runpod's pod template page.

## Reproducible notebooks by design

This image is designed so that every notebook is fully self-contained and reproducible anywhere.

Marimo is launched with [`--sandbox`](https://docs.marimo.io/guides/package_management/inlining_dependencies/), which runs each notebook in its own isolated `uv` environment built from the notebook's [PEP 723](https://peps.python.org/pep-0723/) inline script metadata.
When you install a package through marimo's built-in package manager, it is written directly into the notebook's header — the notebook carries its own dependency list and will run identically on any machine with `uv` installed.

This image also intentionally does **not** include marimo's `recommended` extras (polars, pandas, matplotlib, etc.).
Pre-installing packages would allow imports that work in the pod but have no record in the notebook, silently breaking reproducibility everywhere else.

## Environment variables

| Variable | Description | Default |
|---|---|---|
| `MARIMO_WORKSPACE` | Path to open in marimo's file browser | `/workspace` |
| `MARIMO_CACHE_DIR` | Parent directory for uv and Hugging Face caches | `$MARIMO_WORKSPACE/.cache` |
| `MARIMO_TOKEN_PASSWORD` | Password required to access the marimo UI | _(falls back to `JUPYTER_PASSWORD`, else a generated token)_ |
| `MARIMO_DISABLE_AUTH` | Set to `true` to disable marimo's token authentication entirely | `false` |

`/workspace` is where Runpod mounts network volumes, so notebooks created through the file browser automatically persist across pod stop/start when a volume is attached.
Without a volume, `/workspace` is a regular container directory (ephemeral).

### CPU pods and Network Volumes

Runpod CPU pods cannot use a Volume Disk (the pod-template API disallows the `persistent` mount on CPU pods), so on the CPU variant the only way to persist `/workspace` is a [Network Volume](https://docs.runpod.io/storage/network-volumes) mounted there.
Without one, `/workspace` lives on the Container Disk, which is wiped every time the pod stops: notebooks are lost, and any packages and models they downloaded must be downloaded again (marimo's own packages are seeded from the image's prewarmed cache, so only notebook-specific dependencies are refetched).
The `uv` and Hugging Face caches also take up Container Disk space, so size it for the packages and models your notebooks use (the published CPU template uses 20 GB, the most Runpod allows for a 2-vCPU pod).

`uv`'s sandbox cache (`UV_CACHE_DIR`) and the Hugging Face hub cache (`HF_HOME`) default to `$MARIMO_WORKSPACE/.cache/uv` and `$MARIMO_WORKSPACE/.cache/huggingface`, so downloaded notebook dependencies and models persist on the volume alongside the notebooks.
marimo itself always launches from the image's prewarmed cache at `/home/runpod/.cache/uv`, so the first boot on a fresh volume needs no download (and no network) to start marimo; only an overridden `MARIMO_VERSION` is downloaded, once, into `UV_CACHE_DIR`.
Notebook sandboxes, by contrast, build from `UV_CACHE_DIR`, so before launch startup seeds it with the package wheels from the image's prewarmed cache. The first notebook opened on a fresh volume then installs marimo and its dependencies from local wheels instead of re-downloading them (uv may still check the index for newer metadata). Seeding runs once per image marimo and uv version (recorded by a `.runpod-marimo-seeded-<marimo>-uv<uv>` marker in the cache; delete it to seed again), never replaces existing cache entries, and on failure only warns, leaving sandboxes to download as before. It does not affect reproducibility: a cache makes nothing importable, and a sandbox still installs exactly what the notebook's header declares.

### Opting out of persistent caches

If you don't want the caches on the volume — e.g. the volume is small, you'd prefer faster local reads, or you're sharing a volume across pods — point `MARIMO_CACHE_DIR` at an in-container path:

```
MARIMO_CACHE_DIR=/home/runpod/.cache
```

That restores ephemeral container-local caches, so notebook dependencies and models are re-downloaded whenever the container is recreated.
`UV_CACHE_DIR` and `HF_HOME` can also be set individually to relocate either cache independently.

> **Shared volumes:** `HF_HOME` stores the Hugging Face auth token (`~/.cache/huggingface/token`), so a volume shared between pods will also share whoever is currently logged in with `huggingface-cli login`. If that's not what you want, keep `HF_HOME` off the shared volume (`HF_HOME=/home/runpod/.cache/huggingface`) while leaving `UV_CACHE_DIR` wherever you want it.

## Authentication

Runpod's web proxy does **not** authenticate requests — anyone with the pod's proxy URL (`https://<pod-id>-2971.proxy.runpod.net`) can reach the marimo server, and a notebook server is arbitrary code execution.
The image therefore enables marimo's token authentication by default, resolving the password in order:

1. `MARIMO_TOKEN_PASSWORD`, if set — an explicit password of your choosing.
2. `JUPYTER_PASSWORD`, if set — Runpod auto-generates this env var for templates that declare it. The console does not display its value anywhere, but unlike a generated token it stays stable across pod stop/start, so a bookmarked access URL keeps working.
3. A random token generated at startup (rotates on every restart).

Whatever the source, the startup logs print a ready-to-use access URL (`https://<pod-id>-2971.proxy.runpod.net/?access_token=...`) — open the pod's logs in the Runpod console to find it. The resolved token is also stored at `/home/runpod/.config/marimo/token`.
The token is passed to marimo via `--token-password-file`, so it does not appear in `ps` output or `/proc/<pid>/cmdline`. It **is** exported as `MARIMO_TOKEN` into login and interactive shell environments, so the bundled [marimo-pair](#pairing-with-a-coding-agent) skill and any agent you bring into the pod can authenticate without setup. This does not widen who can read it: every identity that gets a shell here (`root`, and `runpod` via marimo) can already read the token file, and the token is printed to the pod logs.

Set `MARIMO_DISABLE_AUTH=true` to opt out and run with `--no-token`. Only do this if something else restricts access to port 2971.

### Users and privileges

marimo runs as the unprivileged `runpod` user; the Runpod console, SSH and `docker exec` give a root shell.
Treat the separate user as hygiene, not as a security boundary: `runpod` has passwordless `sudo` for `apt-get` and `apt` so packages can be installed from the marimo terminal, and apt is root-equivalent by design (maintainer scripts run as root, and `apt-get -o APT::Update::Pre-Invoke=<cmd>` runs any command as root).
Anything running as `runpod` — every notebook cell — can therefore become root.
What the separate user does provide is unprivileged defaults: files created by notebooks are not root-owned, a mistake inside a cell cannot take out system directories, and per-user caches live in a predictable place.
The pod is single-tenant, so this matches the access the console already grants; the token file's `0600` mode protects against accidental reads, not against a hostile notebook.

> **Environment variable forwarding:** all environment variables set on the pod — including API keys and other credentials — are forwarded into the marimo and SSH login shell environments so that notebook code can reach them.
> Be aware that any secret set on the pod is accessible from notebook code.

## What is included

- **marimo** with `lsp` (in-editor autocomplete, linting, and type checking via **ty**) and `mcp` extras
- **Node.js** (current LTS, `node` binary only — no npm), required by marimo's language-server bridge; installed from the upstream release tarball rather than Ubuntu's end-of-life Node 18 package
- **huggingface_hub** CLI for downloading models and datasets
- **GitHub CLI** (`gh`) and **runpodctl** for interacting with Runpod and GitHub from the terminal
- **DuckDB** CLI for querying files from the terminal
- **[pi](https://pi.dev)** and **[opencode](https://opencode.ai)** coding-agent CLIs, as pinned standalone binaries
- **[marimo-pair](https://github.com/marimo-team/marimo-pair)** agent skill, preinstalled so a coding agent can drive the live notebook kernel
- Standard utilities: `git`, `curl`, `wget`, `jq`, `tmux`
- **nvtop** for GPU monitoring (GPU variant only)

## Pairing with a coding agent

Two coding-agent CLIs ship preinstalled: [pi](https://pi.dev) and [opencode](https://opencode.ai).
Each is a pinned, checksum-verified standalone release binary — no Node toolchain is involved — and neither adds anything importable from a notebook.
pi lives under `/opt/pi` behind a launcher at `/usr/local/bin/pi`; opencode is `/usr/local/bin/opencode`.
Both need an API key for your model provider: set it as a pod environment variable (for example `ANTHROPIC_API_KEY`), which the image forwards into shell environments, or authenticate inside the agent (`/login` in pi, `/connect` in opencode).

The [marimo-pair](https://github.com/marimo-team/marimo-pair) skill also ships preinstalled.
It lets a coding agent run Python in the *same kernel you are using* and commit durable cell changes, instead of editing the notebook file behind the running kernel's back.

The skill is installed at `/opt/agent-skills/marimo-pair` and linked into the locations agent harnesses scan, for both the `root` and `runpod` users:

- `~/.claude/skills/marimo-pair` — Claude Code
- `~/.agents/skills/marimo-pair` — the cross-client [Agent Skills](https://agentskills.io) convention

pi and opencode both scan `~/.agents/skills`, so they pick the skill up with no configuration; the same links serve a Claude Code or Codex you bring yourself.

Open a notebook in the browser, launch the agent from a pod terminal (the Runpod web terminal, SSH, or `docker exec -it`), and point it at the local server:

```
http://localhost:2971
```

Give the URL explicitly. marimo's auto-discovery only registers servers started with `--no-token`, and this image enables token authentication by default.

The resolved token is already exported as `MARIMO_TOKEN` in login shells and in interactive shells (the Runpod web terminal, SSH, `docker exec -it`), so an agent launched from one of those needs no further setup. A *non-interactive* shell — `docker exec <pod> bash -c '...'` — sources neither startup file, so export it yourself there:

```bash
export MARIMO_TOKEN=$(cat /home/runpod/.config/marimo/token)
```

Harnesses other than Claude Code and Codex may scan different directories; point yours at `/opt/agent-skills/marimo-pair` if it does not pick the skill up.

## Building

Images are built and published to [GitHub Container Registry](https://ghcr.io) automatically when a version tag (`v*.*.*`) is pushed.

To build locally:

```bash
# GPU (default)
docker build -t runpod-marimo:gpu .

# CPU
docker build -t runpod-marimo:cpu \
  --build-arg VARIANT=cpu \
  --build-arg "IMAGE_DESCRIPTION=Marimo notebook server for Runpod CPU pods" .
```
