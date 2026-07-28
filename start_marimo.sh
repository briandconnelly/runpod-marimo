#!/bin/bash
set -Eeuo pipefail

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

# Ensure a directory exists and is owned by the runpod user. Only chowns
# directories we created on this boot, to avoid changing ownership of
# a pre-existing user-supplied path (e.g. a populated volume subdir).
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
        chown runpod:runpod "$dir" || {
            echo "Error: failed to chown '$dir' to runpod." >&2
            exit 1
        }
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
# by the runpod user before launching marimo. The dir-setup above
# should guarantee this for paths we created, but _ensure_runpod_dir
# intentionally leaves ownership alone on pre-existing user-supplied
# paths — so a user-provided MARIMO_CACHE_DIR / UV_CACHE_DIR / HF_HOME
# pointing at a root-owned or ACL-restricted dir would slip through
# silently and fail later when marimo/uv tries to write. Same goes for
# a network volume with restrictive ACLs or a read-only mount. Each
# failure mode produces a specific error here instead of a cryptic
# cache/notebook-save failure after marimo is already running.
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
#   1. MARIMO_DISABLE_AUTH=true  → --no-token (explicit opt-out).
#   2. MARIMO_TOKEN_PASSWORD     → user-chosen password.
#   3. JUPYTER_PASSWORD          → Runpod auto-generates this for templates
#                                  that declare it. The console does NOT
#                                  display its value anywhere, but unlike a
#                                  generated token it stays stable across
#                                  pod stop/start.
#   4. A random token (rotates every boot).
# Whatever the source, the one place a user can always find the token is
# the pod logs: a ready-to-use proxy access URL is printed below.
# The token is handed to marimo via --token-password-file rather than a
# command-line flag so it never appears in `ps` / /proc/<pid>/cmdline. The
# file is runpod-owned mode 0600: marimo (running as runpod) must read it,
# and anything already running as runpod is post-auth anyway.
TOKEN_FILE=/home/runpod/.config/marimo/token
if [[ "${MARIMO_DISABLE_AUTH:-}" == "true" ]]; then
    echo "Warning: MARIMO_DISABLE_AUTH=true — the marimo UI is reachable without a password by anyone with this pod's proxy URL." >&2
    AUTH_FLAG="--no-token"
else
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
    install -o runpod -g runpod -m 0600 /dev/null "$TOKEN_FILE" || {
        echo "Error: failed to create token file '$TOKEN_FILE'." >&2
        exit 1
    }
    printf '%s' "$TOKEN_VALUE" > "$TOKEN_FILE"
    AUTH_FLAG=$(printf -- '--token-password-file %q' "$TOKEN_FILE")

    # Print a clickable, token-pre-filled proxy URL. This is the token's
    # discoverability story: the Runpod console shows neither JUPYTER_PASSWORD
    # nor anything we generate, so the pod logs are the one place a user can
    # always look. jq URL-encodes the token so user-chosen passwords with
    # special characters produce a working link. Logs are only visible to
    # the console-authenticated pod owner, and marimo itself already prints
    # a localhost URL with the same token.
    if [[ -n "${RUNPOD_POD_ID:-}" ]]; then
        TOKEN_URI=$(jq -rn --arg v "$TOKEN_VALUE" '$v|@uri')
        echo "Access marimo at: https://${RUNPOD_POD_ID}-2971.proxy.runpod.net/?access_token=${TOKEN_URI}"
    fi
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
# uvx creates a clean isolated environment on first launch and reuses the
# cached environment on subsequent starts.
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
MARIMO_SPEC_Q=$(printf '%q' "marimo[mcp,lsp]==${MARIMO_VERSION}")
exec su -l runpod -c "cd ${WORKSPACE_Q} && uvx ${MARIMO_SPEC_Q} $MARIMO_ARGS"
