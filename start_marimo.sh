#!/bin/bash
set -Eeuo pipefail

# Run under tini when started as PID 1, so processes orphaned by terminals
# and agents are reaped instead of piling up as zombies (su, the eventual
# PID 1 otherwise, never waits on them). No -g: the su -> uv -> marimo chain
# below forwards SIGTERM link by link, and tini forwards it to su. Keeping
# CMD as this script means template command overrides and test entrypoints
# that exec it still get tini.
if [[ $$ -eq 1 && -x /usr/bin/tini ]]; then
    exec /usr/bin/tini -- "$0" "$@"
fi

# marimo always runs with token auth (see Authentication below). The old
# MARIMO_DISABLE_AUTH opt-out was removed; setting it to anything but
# "false" (its documented default, still present in existing templates)
# stops the pod before any setup rather than being silently ignored.
if [[ -n "${MARIMO_DISABLE_AUTH:-}" && "${MARIMO_DISABLE_AUTH}" != "false" ]]; then
    echo "Error: MARIMO_DISABLE_AUTH is no longer supported; marimo always requires a token. Unset it, and set MARIMO_TOKEN_PASSWORD if you want a fixed password." >&2
    exit 1
fi

# Optional user hook that runs before services (SSH, env forwarding) start.
# Treated as a required setup step: any failure aborts startup.
if [[ -f /pre_start.sh ]]; then
    echo "Running /pre_start.sh..."
    if ! bash /pre_start.sh; then
        echo "Error: /pre_start.sh failed; aborting startup." >&2
        exit 1
    fi
fi

# If the pod was launched with a PUBLIC_KEY (standard Runpod convention),
# authorize it for root and start sshd. DSA is intentionally omitted — it is
# deprecated since OpenSSH 7.0 and unavailable in recent releases.
# SSH failures abort: a user who provided PUBLIC_KEY expects to be able to
# SSH in, so silent failure would be worse than an explicit exit.
if [[ -n "${PUBLIC_KEY:-}" ]]; then
    echo "Setting up SSH..."
    mkdir -p /root/.ssh
    # Idempotent: avoid duplicate entries across pod stop/start cycles.
    # PUBLIC_KEY can hold several newline-separated keys (Runpod sends every
    # key on the account), so dedup per key. A single grep against the whole
    # variable would treat each line as an independent -F pattern and skip
    # the append when ANY one key already matched, silently dropping the rest.
    touch /root/.ssh/authorized_keys
    while IFS= read -r pubkey; do
        [[ -z "$pubkey" ]] && continue
        if ! grep -Fxq -- "$pubkey" /root/.ssh/authorized_keys; then
            printf '%s\n' "$pubkey" >> /root/.ssh/authorized_keys
        fi
    done <<< "$PUBLIC_KEY"
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys

    for keytype in rsa ecdsa ed25519; do
        keyfile="/etc/ssh/ssh_host_${keytype}_key"
        if [[ ! -f "$keyfile" ]]; then
            if ! ssh-keygen -t "$keytype" -f "$keyfile" -q -N ''; then
                echo "Error: failed to generate SSH host key '$keyfile'" >&2
                exit 1
            fi
        fi
    done

    # On Ubuntu 24.04 openssh-server relies on systemd to create /run/sshd
    # via a RuntimeDirectory= unit directive. In a non-systemd container,
    # that directory is never created and sshd fails with "Missing privilege
    # separation directory". Create it explicitly before starting the service.
    mkdir -p /run/sshd

    if ! service ssh start; then
        echo "Error: failed to start sshd after PUBLIC_KEY was provided" >&2
        exit 1
    fi
fi

# ── Workspace and cache directories ──────────────────────────────────────────
# marimo's file browser opens to WORKSPACE. Notebooks and the per-sandbox
# uv caches and HF model downloads are rooted here so a Runpod network
# volume attached at /workspace persists everything across pod stop/start.
#
# WORKSPACE selection:
#   1. MARIMO_WORKSPACE if set (user override).
#   2. /workspace unconditionally, matching Runpod's volume-mount convention.
#      When no volume is attached /workspace is just a fresh container dir;
#      we create it on the spot.
#
# Cache root (UV_CACHE_DIR, HF_HOME):
#   1. Individual UV_CACHE_DIR / HF_HOME if set (fine-grained user override).
#   2. MARIMO_CACHE_DIR as a grouped override (e.g. set to /home/runpod/.cache
#      to force ephemeral container-local caches even when /workspace is a
#      persistent volume).
#   3. <workspace>/.cache, so a user who attaches a volume automatically
#      gets persistent uv sandbox builds and HF downloads in addition to
#      their notebooks.

# Validate the user-supplied path knobs. A misconfigured env var ("/",
# " ", a relative path, or one with traversal like `/tmp/../../etc/...`)
# could otherwise chown a system path we take ownership of below, or
# land notebooks somewhere the user can't find them. We canonicalize
# with `readlink -m` first (which resolves `..` / symlinks without
# requiring the path to exist) so denylist checks can't be bypassed by
# traversal. The canonicalized value is written back to the original
# env var so downstream code uses the resolved path.
_validate_path_var() {
    local name="$1" value="$2" canonical
    if [[ -z "$value" || "$value" != /* ]]; then
        echo "Error: $name must be a non-empty absolute path; got '$value'." >&2
        exit 1
    fi
    if ! canonical=$(readlink -m -- "$value"); then
        echo "Error: failed to canonicalize $name path '$value'." >&2
        exit 1
    fi
    case "$canonical" in
        /|/bin|/boot|/dev|/etc|/lib|/lib32|/lib64|/proc|/root|/run|/sbin|/sys|/usr|/var)
            echo "Error: $name refuses to take ownership of system path '$canonical' (resolved from '$value')." >&2
            exit 1
            ;;
        /bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib32/*|/lib64/*|/proc/*|/root/*|/run/*|/sbin/*|/sys/*|/usr/*|/var/*)
            echo "Error: $name refuses to take ownership of a path under a system directory: '$canonical' (resolved from '$value')." >&2
            exit 1
            ;;
    esac
    printf -v "$name" '%s' "$canonical"
    # shellcheck disable=SC2163  # $name intentionally holds the variable's name
    export "$name"
}
[[ -n "${MARIMO_WORKSPACE:-}" ]] && _validate_path_var MARIMO_WORKSPACE "$MARIMO_WORKSPACE"
[[ -n "${MARIMO_CACHE_DIR:-}" ]] && _validate_path_var MARIMO_CACHE_DIR "$MARIMO_CACHE_DIR"
[[ -n "${UV_CACHE_DIR:-}" ]] && _validate_path_var UV_CACHE_DIR "$UV_CACHE_DIR"
[[ -n "${HF_HOME:-}" ]] && _validate_path_var HF_HOME "$HF_HOME"

# Ensure a directory exists and try to give the runpod user ownership.
# A denied chown on a new directory falls back to chmod 1777 and warns:
# the probes below decide whether runpod can use the paths. Only chowns
# directories we created on this boot, to avoid changing ownership of a
# pre-existing user-supplied path (e.g. a populated volume subdir).
# Special case: /workspace itself is always chown'd because Runpod mounts
# network volumes there root-owned, and marimo (unprivileged) must be
# able to write at the top level.
_ensure_runpod_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        if [[ "$dir" == "/workspace" ]]; then
            chown runpod:runpod "$dir" || {
                echo "Warning: could not chown '$dir' to runpod; marimo may fail to write notebooks." >&2
            }
        fi
    else
        mkdir -p "$dir" || {
            echo "Error: failed to create '$dir'." >&2
            exit 1
        }
        # Some volumes deny chown but honor root's umask, so the new
        # directory is root-owned 0755 and unusable by runpod (Runpod's
        # NFS-backed pod volumes do; its MooseFS ones create every
        # directory 0777). Root can still chmod a directory it owns, so
        # open this one up instead. Sticky, like /tmp. The probes below
        # still decide whether runpod can use it.
        if ! chown runpod:runpod "$dir"; then
            if chmod 1777 "$dir"; then
                echo "Warning: could not chown '$dir' to runpod; made it world-writable (mode 1777) instead." >&2
            else
                echo "Warning: could not chown '$dir' to runpod; checking directory permissions below." >&2
            fi
        fi
    fi
}

WORKSPACE="${MARIMO_WORKSPACE:-/workspace}"
_ensure_runpod_dir "$WORKSPACE"

CACHE_ROOT="${MARIMO_CACHE_DIR:-${WORKSPACE}/.cache}"
# These exports are load-bearing — they flow into the parent process's
# env, get captured by _forward_env below, and from there land in
# /etc/profile.d/zz-pod-env.sh so marimo's `su -l runpod` login shell
# (which would otherwise wipe them) picks them up. Do not move this
# block after _forward_env without re-wiring the propagation.
export UV_CACHE_DIR="${UV_CACHE_DIR:-$CACHE_ROOT/uv}"
export HF_HOME="${HF_HOME:-$CACHE_ROOT/huggingface}"
_ensure_runpod_dir "$CACHE_ROOT"
_ensure_runpod_dir "$UV_CACHE_DIR"
_ensure_runpod_dir "$HF_HOME"

# Probe that the workspace and cache directories are actually usable
# by the runpod user before launching marimo, even if chown was denied
# or ownership was left alone on a pre-existing user-supplied path.
# Restrictive permissions, ACLs or read-only mounts produce a specific
# error on the first boot instead of a cryptic cache/notebook-save failure
# after marimo is already running. CACHE_ROOT itself only needs traversal
# when the caches live under it; probing those children covers that too.
# Directories need both the write bit and the execute (search) bit
# for file creation, so check both.
_probe_runpod_writable() {
    local label="$1" path="$2" path_q
    path_q=$(printf '%q' "$path")
    if ! su -l runpod -c "test -w $path_q && test -x $path_q"; then
        echo "Error: $label '$path' is not writable by the runpod user." >&2
        echo "       Check mount permissions and ACLs, or set MARIMO_WORKSPACE / MARIMO_CACHE_DIR to a usable path." >&2
        exit 1
    fi
}
_probe_runpod_writable "workspace" "$WORKSPACE"
_probe_runpod_writable "UV_CACHE_DIR" "$UV_CACHE_DIR"
_probe_runpod_writable "HF_HOME" "$HF_HOME"

# Forward container environment variables to the runpod user's login shell.
# `su -l` (used below) starts a clean login shell that discards the parent
# process's environment. Env vars set by users when configuring their Runpod
# pod would otherwise be invisible to marimo. Writing them to a profile.d
# script ensures they are available. The zz- prefix makes it sort after
# runpod-env.sh so user overrides take precedence over build-time defaults
# (in C locale, digits sort before letters, so a numeric prefix would not
# achieve this).
#
# NOTE: nearly all pod env vars — including API keys and other credentials —
# are forwarded into the marimo/SSH login shell environment. This is intentional
# (users set API keys as pod env vars precisely to use them in notebooks), but
# means any credential set on the pod is accessible from notebook code.
_forward_env() {
    while IFS= read -r -d '' entry; do
        local key="${entry%%=*}"
        local value="${entry#*=}"
        case "$key" in
            # System variables managed by the login shell itself
            HOME|USER|LOGNAME|SHELL|TERM|PATH|SHLVL|PWD|OLDPWD|_|HOSTNAME) continue ;;
            # Bash readonly variables that would error on re-export
            BASHOPTS|SHELLOPTS) continue ;;
            # Consumed at boot by SSH setup / marimo token-auth resolution;
            # all are credentials or startup-only and have no use in the
            # notebook env.
            PUBLIC_KEY|JUPYTER_PASSWORD|MARIMO_TOKEN_PASSWORD|MARIMO_DISABLE_AUTH) continue ;;
            # Owned by the Authentication block below, which appends the
            # resolved token to this file. Forwarding an inbound value here
            # would export a second, stale MARIMO_TOKEN ahead of the
            # authoritative append.
            MARIMO_TOKEN) continue ;;
        esac
        # Skip entries that aren't valid shell identifiers (e.g. BASH_FUNC_*%%)
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        printf "export %s=%q\n" "$key" "$value"
    done < <(env -0)
}
POD_ENV_FILE="/etc/profile.d/zz-pod-env.sh"
install -o root -g runpod -m 0640 /dev/null "$POD_ENV_FILE" || {
    echo "Failed to create $POD_ENV_FILE with secure permissions" >&2
    exit 1
}
if ! _forward_env > "$POD_ENV_FILE"; then
    echo "Failed to write forwarded environment to $POD_ENV_FILE" >&2
    exit 1
fi

# Optional user hook that runs after services are up and before marimo starts.
# Failures are logged but do not block marimo startup — a post-start hook that
# breaks should not prevent the notebook server from coming up.
if [[ -f /post_start.sh ]]; then
    echo "Running /post_start.sh..."
    if ! bash /post_start.sh; then
        echo "Warning: /post_start.sh failed; continuing to start marimo." >&2
    fi
fi

# ── Authentication ───────────────────────────────────────────────────────────
# Runpod's web proxy does NOT authenticate requests: anyone with the pod's
# proxy URL (https://<pod-id>-2971.proxy.runpod.net) reaches this server, and
# a marimo editor is arbitrary code execution. Token auth is therefore ON by
# default; the password is resolved in order:
#   1. MARIMO_TOKEN_PASSWORD     → user-chosen password.
#   2. JUPYTER_PASSWORD          → Runpod auto-generates this for templates
#                                  that declare it. The console does NOT
#                                  display its value anywhere, but unlike a
#                                  generated token it stays stable across
#                                  pod stop/start.
#   3. A random token (rotates every boot).
# There is deliberately no way to run without a token; see the
# MARIMO_DISABLE_AUTH guard at the top of this script.
# Whatever the source, the one place a user can always find the token is
# the pod logs: a ready-to-use proxy access URL is printed below.
# The token is handed to marimo via --token-password-file rather than a
# command-line flag so it never appears in `ps` / /proc/<pid>/cmdline. The
# file is runpod-owned mode 0600: marimo (running as runpod) must read it,
# and anything already running as runpod is post-auth anyway.
TOKEN_FILE=/home/runpod/.config/marimo/token
if [[ -n "${MARIMO_TOKEN_PASSWORD:-}" ]]; then
    echo "Token authentication enabled (MARIMO_TOKEN_PASSWORD)."
    TOKEN_VALUE="$MARIMO_TOKEN_PASSWORD"
elif [[ -n "${JUPYTER_PASSWORD:-}" ]]; then
    echo "Token authentication enabled; using JUPYTER_PASSWORD as the access token."
    TOKEN_VALUE="$JUPYTER_PASSWORD"
else
    echo "Token authentication enabled with a generated token; see the access URL below or ${TOKEN_FILE}."
    # head reads a fixed byte count before base64 runs, so no SIGPIPE
    # under pipefail. 24 random bytes → 32 base64 chars before stripping.
    TOKEN_VALUE=$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n')
fi
# Created as runpod rather than `install -o runpod`, so this needs no
# CAP_CHOWN (CI drops it to emulate volumes that deny chown).
runuser -u runpod -- install -m 0600 /dev/null "$TOKEN_FILE" || {
    echo "Error: failed to create token file '$TOKEN_FILE'." >&2
    exit 1
}
printf '%s' "$TOKEN_VALUE" > "$TOKEN_FILE"
AUTH_FLAG=$(printf -- '--token-password-file %q' "$TOKEN_FILE")

# Export the resolved token into the login-shell environment so the
# bundled marimo-pair skill — and any agent a user brings into the pod —
# can authenticate against :2971 with no setup. The skill's scripts read
# MARIMO_TOKEN precisely so the token stays out of `ps`.
#
# This widens the token's reach from the 0600 file to every login shell,
# and the READMEs say so. The exposure is small in practice: both
# identities that get a shell here (root, and runpod via marimo) can
# already read TOKEN_FILE, and the token is printed to the pod logs.
# POD_ENV_FILE is 0640 root:runpod and already carries every other pod
# credential. Appended rather than written by _forward_env above because
# that runs before the token exists.
printf 'export MARIMO_TOKEN=%q\n' "$TOKEN_VALUE" >> "$POD_ENV_FILE"

# Print a clickable, token-pre-filled proxy URL. This is the token's
# discoverability story: the Runpod console shows neither JUPYTER_PASSWORD
# nor anything we generate, so the pod logs are the one place a user can
# always look. jq URL-encodes the token so user-chosen passwords with
# special characters produce a working link; the token reaches jq on stdin
# so it never appears on a command line. Logs are only visible to
# the console-authenticated pod owner, and marimo itself already prints
# a localhost URL with the same token.
if [[ -n "${RUNPOD_POD_ID:-}" ]]; then
    TOKEN_URI=$(printf '%s' "$TOKEN_VALUE" | jq -sRr '@uri')
    echo "Access marimo at: https://${RUNPOD_POD_ID}-2971.proxy.runpod.net/?access_token=${TOKEN_URI}"
fi

# Launch marimo editor as the runpod user.
# --host 0.0.0.0       : bind to all interfaces so Runpod's proxy can reach it
# --port 2971          : marimo's default port (exposed in the Runpod template config)
# --sandbox            : run each notebook in an isolated uv environment derived from
#                        its PEP 723 inline script metadata, ensuring reproducibility
#
# MARIMO_ARGS is interpolated into `su -l runpod -c "uvx ... $MARIMO_ARGS"` below,
# so the string is re-parsed as a shell command by the su-invoked shell. Every
# value substituted in from the environment (workspace path, token file path) is
# pre-escaped with `printf %q` so special characters survive that second parse
# unchanged and cannot inject commands — this script runs as root, so unescaped
# interpolation of user-controlled env vars would be a privilege-escalation hole.
WORKSPACE_Q=$(printf '%q' "$WORKSPACE")
MARIMO_ARGS="edit --host 0.0.0.0 --port 2971 ${AUTH_FLAG} --sandbox ${WORKSPACE_Q}"

# MARIMO_VERSION is set at build time (Dockerfile ARG → ENV → /etc/profile.d/)
# and pins the exact marimo release so the image is deterministic.
# uvx reuses the image's prewarmed environment when MARIMO_VERSION is the
# build-time version (see "Prewarmed launch" below), and otherwise creates
# one on first launch and reuses it on subsequent starts.
# Pre-escape the full package spec: `printf %q` protects both the version
# value and the `[mcp,lsp]` glob characters from re-expansion by the su -l
# shell, avoiding command injection through MARIMO_VERSION and spurious
# glob matches against the runpod user's cwd.
#
# `cd $WORKSPACE` before exec: `su -l` lands in /home/runpod, but marimo's
# file-upload destination and any relative paths resolved from notebook
# code use the process cwd, not marimo's --sandbox arg. Without this cd,
# files uploaded through marimo's UI land in /home/runpod (ephemeral
# container state) even though the file browser shows /workspace.
#
# No `--with 'mcp<2'` cap: marimo 0.24.1 moved to the mcp 2.x API and its
# [mcp] extra now declares `mcp>=2.0.0,<3`, so marimo bounds the dependency
# itself. The cap this replaces existed because 0.23.x declared an unbounded
# `mcp>=1.0.0` while importing symbols mcp 2.0.0 removed
# (marimo-team/marimo#10371); re-adding a cap here would now make the resolve
# unsatisfiable.
#
# The cost of having no cap is that overriding MARIMO_VERSION *down* to a
# 0.23.x release resolves mcp 2.x against a marimo that predates it, leaving
# MCP unavailable (marimo itself still starts). That is the pre-0.8.1
# behaviour, and it is unavoidable with a static cap: 0.23.x needs mcp<2 and
# 0.24.1+ refuses it. Version-conditional capping is deliberately not
# attempted here — it would branch on an unvalidated env var inside the
# string handed to `su -c`, and would split the prewarmed uvx cache.
#
# The requirement set here must stay in sync with the prewarm in the
# Dockerfile: uvx keys its cached tool env on the full set, so adding a
# `--with` on one side silently turns first boot into a fresh download
# instead of a cache hit.
#
# Process tree and shutdown. tini is PID 1 (see the top of this script) and
# forwards SIGTERM to `exec su`, its child; util-linux su forwards
# SIGTERM/SIGINT to its child. That child is the `-c` shell, and
# a non-interactive bash receiving SIGTERM simply dies, orphaning whatever
# it was waiting on — so without the inner `exec`, a pod stop would kill
# the shell and leave marimo running until Docker's SIGKILL deadline,
# skipping marimo's own shutdown (kernel teardown, autosave). With it,
# bash execs uv. uv does not exec the tool: its runner spawns marimo and
# waits, but it forwards SIGTERM (and SIGINT when stdin is not a TTY) to
# the child precisely for this PID-1/Docker case. So the tree is
# tini(1) -> su -> uv -> marimo with every link forwarding, and the shell — the
# one non-forwarding link — is gone. tests/common.sh asserts that shape.
#
# Prewarmed launch (#50). The image prewarms marimo into
# /home/runpod/.cache/uv, but UV_CACHE_DIR defaults to the workspace volume,
# so a plain `uvx` on a fresh volume re-downloaded marimo from PyPI — slow on
# a healthy pod, and a crash loop on one without network. `--cache-dir`
# points only this uvx invocation at the prewarmed cache: uv does not
# rewrite UV_CACHE_DIR for the child, so marimo and its --sandbox `uv`
# subprocesses still inherit the volume cache exported above, seeded below
# before any uv process starts.
# The flag is applied only when MARIMO_VERSION is the version the image
# prewarmed; a runtime override resolves into UV_CACHE_DIR as before, where
# it persists on the volume.
UVX_CACHE_ARG=""
PREWARMED_VERSION=""
if [[ -r /usr/local/share/runpod-marimo/prewarmed-marimo-version ]]; then
    IFS= read -r PREWARMED_VERSION < /usr/local/share/runpod-marimo/prewarmed-marimo-version || true
fi

# Seed the volume's uv cache from the image's prewarmed one (#116). The
# launcher above runs from the prewarmed cache, but each notebook's --sandbox
# `uv sync` uses UV_CACHE_DIR, which is empty on a fresh volume, so without
# this every first notebook open re-downloads marimo and its dependencies.
# Only package and interpreter buckets are copied, never cached tool or
# script environments. A cache makes nothing importable: a sandbox installs
# exactly what the notebook's PEP 723 header declares, wherever the wheels
# come from. Wheel entries are relative symlinks into archive-v0, so the
# copy is self-contained.
# The copy goes to a staging dir inside the cache, and each entry is then
# moved into place with rename(2), so it lands whole or not at all: a pod
# stopped mid-seed cannot leave a truncated file that uv would later trust.
# Existing entries are never replaced, and atomic placement keeps a uv in
# another pod sharing this cache from ever seeing a partial entry. Runs as
# runpod so it needs no chown (#115). A versioned marker makes it once per
# image marimo and uv version; a failure warns and leaves no marker, so the
# next boot retries and sandboxes fall back to downloads.
PREWARMED_CACHE=/home/runpod/.cache/uv
UV_VERSION_SEED=$(uv --version 2>/dev/null | awk '{print $2}')
if [[ -n "$PREWARMED_VERSION" && -n "$UV_VERSION_SEED" && -d "$PREWARMED_CACHE" && ! "$UV_CACHE_DIR" -ef "$PREWARMED_CACHE" ]]; then
    # Keyed on uv's version too: a uv upgrade can move a bucket to a new
    # format (wheels-v7 -> wheels-v8), which an older seed never copied.
    SEED_MARKER="$UV_CACHE_DIR/.runpod-marimo-seeded-${PREWARMED_VERSION}-uv${UV_VERSION_SEED}"
    if [[ ! -e "$SEED_MARKER" ]]; then
        echo "Seeding ${UV_CACHE_DIR} from the image's prewarmed uv cache (once per image marimo and uv version)..."
        UV_CACHE_Q=$(printf '%q' "$UV_CACHE_DIR")
        SEED_MARKER_Q=$(printf '%q' "$SEED_MARKER")
        if su -l runpod -c "bash -s -- $UV_CACHE_Q $SEED_MARKER_Q" <<'SEED'
cache=$1
marker=$2
src=/home/runpod/.cache/uv
# Pods can share one cache on a network volume, so each seed gets its own
# staging dir. Ones abandoned by an interrupted boot are swept after an hour.
find "$cache" -mindepth 1 -maxdepth 1 -name '.runpod-marimo-seed.*' -mmin +60 \
    -exec rm -rf -- {} + 2>/dev/null
staging=$(mktemp -d "$cache/.runpod-marimo-seed.XXXXXX") || exit 1
trap 'cd / && rm -rf -- "$staging" "$staging.list"' EXIT
for bucket in "$src"/{archive-v0,wheels-v*,simple-v*,sdists-v*,interpreter-v*}; do
    [[ -d "$bucket" ]] || continue
    cp -R -- "$bucket" "$staging/" || exit 1
done
cd -- "$staging" || exit 1
# Move an entry into place unless one exists. `mv -n` renames with
# RENAME_NOREPLACE, so an entry another pod's uv publishes after the
# existence check is kept rather than overwritten (coreutils falls back to
# check-then-rename only on filesystems without RENAME_NOREPLACE). A skipped
# move exits nonzero; it is a success when the destination now exists.
_place() {
    [[ -e "$cache/$1" || -L "$cache/$1" ]] && return 0
    mkdir -p -- "$cache/$(dirname -- "$1")" || return 1
    mv -n -T -- "$1" "$cache/$1" 2>/dev/null || [[ -e "$cache/$1" || -L "$cache/$1" ]]
}
# archive-v0 first, so no wheel symlink is ever moved in ahead of its target.
# Its entries are immutable, content-addressed directories: move each whole.
for entry in archive-v0/*; do
    [[ -e "$entry" ]] || continue
    _place "$entry" || exit 1
done
find . -path ./archive-v0 -prune -o \( -type f -o -type l \) -print0 > "$staging.list" || exit 1
while IFS= read -r -d '' path; do
    _place "${path#./}" || exit 1
done < "$staging.list"
touch -- "$marker"
SEED
        then
            echo "Seeded uv package cache for marimo ${PREWARMED_VERSION} into ${UV_CACHE_DIR}."
        else
            echo "Warning: could not seed uv cache at '${UV_CACHE_DIR}'; notebook sandboxes may need downloads." >&2
        fi
    fi
fi

MARIMO_SPEC_Q=$(printf '%q' "marimo[mcp,lsp]==${MARIMO_VERSION}")
if [[ -n "$PREWARMED_VERSION" && "$PREWARMED_VERSION" == "$MARIMO_VERSION" ]]; then
    UVX_CACHE_ARG="--cache-dir /home/runpod/.cache/uv"
    # Even a fully cached uvx revalidates its cached PyPI index responses once
    # they go stale (minutes after the image build), so without network the
    # prewarmed launch still failed with a DNS error. The prewarm resolved the
    # exact requirement set already, so launch --offline when a quick offline
    # resolve proves the cache is complete. The probe runs separately, rather
    # than as an `||` fallback on the launch, to keep a shell out of marimo's
    # process ancestry (signal forwarding depends on it).
    if su -l runpod -c "uvx --offline ${UVX_CACHE_ARG} ${MARIMO_SPEC_Q} --version" >/dev/null 2>&1; then
        UVX_CACHE_ARG="--offline ${UVX_CACHE_ARG}"
        echo "Launching marimo ${MARIMO_VERSION} offline from the image's prewarmed uv cache."
    else
        echo "Launching marimo ${MARIMO_VERSION} from the image's prewarmed uv cache (offline resolve failed; uvx may contact PyPI)."
    fi
else
    echo "MARIMO_VERSION=${MARIMO_VERSION} differs from the prewarmed ${PREWARMED_VERSION:-<none>}; uvx will download it into ${UV_CACHE_DIR}."
fi
exec su -l runpod -c "cd ${WORKSPACE_Q} && exec uvx ${UVX_CACHE_ARG} ${MARIMO_SPEC_Q} $MARIMO_ARGS"
