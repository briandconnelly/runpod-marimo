# runpod-marimo (CPU)

A Docker image that runs [marimo](https://marimo.io) as a notebook server on Runpod CPU pods.
Marimo is served on port **2971** and is accessible via Runpod's web proxy.

A GPU variant of this image is also published for CUDA-enabled pods — use a tag without the `-cpu` suffix (e.g., `0.8.1`).

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

`uv`'s sandbox cache (`UV_CACHE_DIR`) and the Hugging Face hub cache (`HF_HOME`) default to `$MARIMO_WORKSPACE/.cache/uv` and `$MARIMO_WORKSPACE/.cache/huggingface`, so downloaded notebook dependencies and models persist on the volume alongside the notebooks.

### Opting out of persistent caches

If you don't want the caches on the volume — e.g. the volume is small, you'd prefer faster local reads, or you're sharing a volume across pods — point `MARIMO_CACHE_DIR` at an in-container path:

```
MARIMO_CACHE_DIR=/home/runpod/.cache
```

That restores ephemeral container-local caches. The image's prewarmed `uvx marimo` cache lives at `/home/runpod/.cache/uv`, so first-boot launches are a cache hit.
`UV_CACHE_DIR` and `HF_HOME` can also be set individually to relocate either cache independently.

> **Shared volumes:** `HF_HOME` stores the Hugging Face auth token (`~/.cache/huggingface/token`), so a volume shared between pods will also share whoever is currently logged in with `huggingface-cli login`. If that's not what you want, keep `HF_HOME` off the shared volume (`HF_HOME=/home/runpod/.cache/huggingface`) while leaving `UV_CACHE_DIR` wherever you want it.

## Authentication

Runpod's web proxy does **not** authenticate requests — anyone with the pod's proxy URL (`https://<pod-id>-2971.proxy.runpod.net`) can reach the marimo server, and a notebook server is arbitrary code execution.
The image therefore enables marimo's token authentication by default, resolving the password in order:

1. `MARIMO_TOKEN_PASSWORD`, if set — an explicit password of your choosing.
2. `JUPYTER_PASSWORD`, if set — Runpod auto-generates this env var for templates that declare it. The console does not display its value anywhere, but unlike a generated token it stays stable across pod stop/start, so a bookmarked access URL keeps working.
3. A random token generated at startup (rotates on every restart).

Whatever the source, the startup logs print a ready-to-use access URL (`https://<pod-id>-2971.proxy.runpod.net/?access_token=...`) — open the pod's logs in the Runpod console to find it. The resolved token is also stored at `/home/runpod/.config/marimo/token`.
The token is passed to marimo via `--token-password-file`, so it does not appear in `ps` output or `/proc/<pid>/cmdline`. It **is** exported as `MARIMO_TOKEN` into the marimo and SSH login shell environments, so the bundled [marimo-pair](#pairing-with-a-coding-agent) skill and any agent you bring into the pod can authenticate without setup. This does not widen who can read it: every identity that gets a shell here (`root`, and `runpod` via marimo) can already read the token file, and the token is printed to the pod logs.

Set `MARIMO_DISABLE_AUTH=true` to opt out and run with `--no-token`. Only do this if something else restricts access to port 2971.

## What is included

- **marimo** with `lsp` (in-editor autocomplete, linting, and type checking via **ty**) and `mcp` extras
- **huggingface_hub** CLI for downloading models and datasets
- **GitHub CLI** (`gh`) and **runpodctl** for interacting with Runpod and GitHub from the terminal
- **DuckDB** CLI for querying files from the terminal
- **[marimo-pair](https://github.com/marimo-team/marimo-pair)** agent skill, preinstalled so a coding agent can drive the live notebook kernel
- Standard utilities: `git`, `curl`, `wget`, `jq`, `tmux`

## Pairing with a coding agent

The [marimo-pair](https://github.com/marimo-team/marimo-pair) skill ships preinstalled.
It lets a coding agent run Python in the *same kernel you are using* and commit durable cell changes, instead of editing the notebook file behind the running kernel's back.

The skill is installed at `/opt/agent-skills/marimo-pair` and linked into the locations agent harnesses scan, for both the `root` and `runpod` users:

- `~/.claude/skills/marimo-pair` — Claude Code
- `~/.agents/skills/marimo-pair` — the cross-client [Agent Skills](https://agentskills.io) convention

Bring your own agent CLI (none is preinstalled), open a notebook in the browser, and point the agent at the local server:

```
http://localhost:2971
```

Give the URL explicitly. marimo's auto-discovery only registers servers started with `--no-token`, and this image enables token authentication by default. The resolved token is already exported as `MARIMO_TOKEN` in every login shell, so no other setup is needed.

Harnesses other than Claude Code and Codex may scan different directories; point yours at `/opt/agent-skills/marimo-pair` if it does not pick the skill up.
