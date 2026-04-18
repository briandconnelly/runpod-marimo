# Shared helpers and test sections for runpod-marimo smoke tests.
# Sourced by tests/test-cpu.sh and tests/test-gpu.sh.

PASS=0
FAIL=0
FAILURES=()

check() {
    local desc="$1"; shift
    if eval "$*" >/dev/null 2>&1; then
        printf '  ok   %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf '  FAIL %s\n' "$desc"
        FAIL=$((FAIL + 1))
        FAILURES+=("$desc")
    fi
}

section() { printf '\n== %s ==\n' "$*"; }

# Verify a directory is usable by the runpod user: both the write bit and
# the execute (search) bit are required to create files inside it, so we
# check both. Argument is a single printf-%q-quoted path so special
# characters survive the `su -l -c` re-parse.
_probe_dir_as_runpod() {
    local path_q="$1"
    su -l runpod -c "test -w $path_q && test -x $path_q"
}

shared_tests() {
    section "Environment"
    echo "MARIMO_VERSION: ${MARIMO_VERSION:-<unset>}"

    section "System packages"
    local cmd
    for cmd in uv uvx gh duckdb runpodctl jq git curl wget tmux node ssh; do
        check "$cmd on PATH" "command -v $cmd"
    done
    check "sshd binary present"     "test -x /usr/sbin/sshd"
    check "Ubuntu 24.04 base"       "grep -qF 'VERSION_ID=\"24.04\"' /etc/os-release"
    check "uv from /usr/local/bin"  "[[ \$(command -v uv)  == /usr/local/bin/uv ]]"
    check "uvx from /usr/local/bin" "[[ \$(command -v uvx) == /usr/local/bin/uvx ]]"

    section "Python tooling"
    check "uv Python 3.13 installed"          "su -l runpod -c 'uv python list --only-installed' 2>/dev/null | grep -q 3.13"
    check "huggingface_hub installed as tool" "su -l runpod -c 'uv tool list' 2>/dev/null | grep -qi huggingface-hub"
    check "ty installed as tool"              "su -l runpod -c 'uv tool list' 2>/dev/null | grep -qw ty"
    check "marimo NOT installed as tool"      "! su -l runpod -c 'uv tool list' 2>/dev/null | grep -qw marimo"

    section "Marimo process"
    local MARIMO_PID MARIMO_USER MARIMO_CMD MARIMO_WS
    MARIMO_PID=$(pgrep -f 'bin/marimo edit' | head -1 || true)
    check "marimo editor running" "test -n '$MARIMO_PID'"
    if [[ -n "$MARIMO_PID" ]]; then
        MARIMO_USER=$(ps -o user= -p "$MARIMO_PID" | tr -d ' ')
        MARIMO_CMD=$(ps -o args= -p "$MARIMO_PID")
        check "marimo runs as 'runpod'"   "[[ '$MARIMO_USER' == runpod ]]"
        check "marimo --sandbox"          "[[ '$MARIMO_CMD' == *--sandbox* ]]"
        check "marimo --host 0.0.0.0"     "[[ '$MARIMO_CMD' == *'--host 0.0.0.0'* ]]"
        check "marimo --port 2971"        "[[ '$MARIMO_CMD' == *'--port 2971'* ]]"
        check "marimo --no-token"         "[[ '$MARIMO_CMD' == *--no-token* ]]"

        # The workspace path is the last positional argument to marimo
        # edit. Read it from /proc/PID/cmdline (NUL-separated, verbatim)
        # rather than `ps -o args`, which reconstructs the command line
        # and can re-quote arguments containing spaces.
        MARIMO_WS=$(tr '\0' '\n' < /proc/"$MARIMO_PID"/cmdline | tail -n 1)
        # Directories need write + execute bits to create new files, so
        # probe both. `printf %q` produces a shell-re-parseable form of
        # the path (e.g. `/a\ b` for `/a b`); we then wrap the whole
        # substitution in double quotes so the eval inside `check` sees
        # it as a single token and the backslash-escapes survive intact
        # all the way into the `su -l -c` inner shell.
        check "marimo workspace usable by runpod" "_probe_dir_as_runpod \"$(printf '%q' "$MARIMO_WS")\""
        if [[ -z "${MARIMO_WORKSPACE:-}" ]]; then
            check "marimo defaults workspace to /workspace" "[[ '$MARIMO_WS' == /workspace ]]"
        fi

        # marimo's cwd must match its workspace arg. `su -l` lands in
        # /home/runpod; without an explicit `cd` before exec, file
        # uploads through marimo's UI and any relative paths resolved
        # from notebook code end up in /home/runpod (ephemeral) even
        # though the file browser shows the workspace. Read the cwd
        # symlink as the process owner since /proc/<pid>/cwd is
        # ptrace-gated and containers do not grant CAP_SYS_PTRACE to
        # root.
        local MARIMO_CWD
        MARIMO_CWD=$(su -l runpod -c "readlink /proc/$MARIMO_PID/cwd" 2>/dev/null || true)
        check "marimo cwd matches workspace" "[[ '$MARIMO_CWD' == '$MARIMO_WS' ]]"
    fi

    section "Cache locations"
    # Caches should live under the workspace by default so they persist
    # on a Runpod network volume. MARIMO_CACHE_DIR overrides to a
    # specific path (common escape hatch: /home/runpod/.cache for
    # ephemeral container storage). Individual UV_CACHE_DIR / HF_HOME
    # still win if set explicitly.
    local MARIMO_ENV_UV MARIMO_ENV_HF EXPECTED_CACHE_ROOT
    if [[ -n "$MARIMO_PID" ]]; then
        # /proc/<pid>/environ is ptrace-gated. Runpod containers do not
        # grant CAP_SYS_PTRACE, so root cannot read another user's environ
        # (EPERM). Read as the process owner instead — same pattern used
        # above for /proc/<pid>/cwd.
        MARIMO_ENV_UV=$(su -l runpod -c "tr '\0' '\n' < /proc/$MARIMO_PID/environ | sed -n 's/^UV_CACHE_DIR=//p'" 2>/dev/null || true)
        MARIMO_ENV_HF=$(su -l runpod -c "tr '\0' '\n' < /proc/$MARIMO_PID/environ | sed -n 's/^HF_HOME=//p'" 2>/dev/null || true)
        check "marimo has UV_CACHE_DIR set" "test -n '$MARIMO_ENV_UV'"
        check "marimo has HF_HOME set"      "test -n '$MARIMO_ENV_HF'"
        if [[ -n "$MARIMO_ENV_UV" ]]; then
            check "UV_CACHE_DIR usable by runpod" "_probe_dir_as_runpod \"$(printf '%q' "$MARIMO_ENV_UV")\""
        fi
        if [[ -n "$MARIMO_ENV_HF" ]]; then
            check "HF_HOME usable by runpod" "_probe_dir_as_runpod \"$(printf '%q' "$MARIMO_ENV_HF")\""
        fi
        if [[ -z "${UV_CACHE_DIR:-}" && -z "${HF_HOME:-}" ]]; then
            EXPECTED_CACHE_ROOT="${MARIMO_CACHE_DIR:-$MARIMO_WS/.cache}"
            check "UV_CACHE_DIR defaults to <cache_root>/uv" \
                "[[ '$MARIMO_ENV_UV' == '$EXPECTED_CACHE_ROOT/uv' ]]"
            check "HF_HOME defaults to <cache_root>/huggingface" \
                "[[ '$MARIMO_ENV_HF' == '$EXPECTED_CACHE_ROOT/huggingface' ]]"
        fi
    fi

    section "HTTP endpoint"
    # First boot against an empty persistent cache (network volume + new
    # UV_CACHE_DIR=/workspace/.cache/uv in 0.5.3) re-downloads marimo's
    # sandbox deps before binding :2971, so a single-shot probe races
    # warmup. Observed >6 min on a shared host under load; retry until a
    # ~10-min wall-clock deadline. Per-attempt --connect-timeout /
    # --max-time caps each curl so a stalled TCP-accepted-but-HTTP-hung
    # server can't push total past the deadline. Wrapped in a subshell
    # so `exit` stays local — `check` uses `eval` in the current shell.
    check "health endpoint 2xx on :2971" \
        "(deadline=\$((\$(date +%s) + 600)); while [[ \$(date +%s) -lt \$deadline ]]; do curl -sfo /dev/null --connect-timeout 3 --max-time 5 http://localhost:2971/ && exit 0; sleep 5; done; exit 1)"

    section "Marimo config"
    local MARIMO_TOML=/home/runpod/.config/marimo/marimo.toml
    check "marimo.toml exists"               "test -r $MARIMO_TOML"
    check "marimo.toml: uv manager"          "grep -qF 'manager = \"uv\"' $MARIMO_TOML"
    check "marimo.toml: ty LSP section"      "grep -qF '[language_servers.ty]' $MARIMO_TOML"
    check "marimo.toml: ty LSP enabled"      "grep -qF 'enabled = true' $MARIMO_TOML"
    check "marimo.toml: mcp marimo preset"   "grep -qF 'presets = [\"marimo\"]' $MARIMO_TOML"

    section "Env forwarding"
    local RE_ENV=/etc/profile.d/runpod-env.sh
    local ZZ_ENV=/etc/profile.d/zz-pod-env.sh
    check "runpod-env.sh exists"                         "test -r $RE_ENV"
    check "runpod-env.sh exports UV path"                "grep -qF 'export UV=/usr/local/bin/uv' $RE_ENV"
    check "runpod-env.sh exports MARIMO_VERSION"         "grep -q 'export MARIMO_VERSION=' $RE_ENV"
    check "zz-pod-env.sh exists"                             "test -r $ZZ_ENV"
    check "zz-pod-env.sh does not leak PUBLIC_KEY"            "! grep -q '^export PUBLIC_KEY' $ZZ_ENV"
    check "zz-pod-env.sh does not leak JUPYTER_PASSWORD"      "! grep -q '^export JUPYTER_PASSWORD' $ZZ_ENV"
    check "zz-pod-env.sh does not leak MARIMO_TOKEN_PASSWORD" "! grep -q '^export MARIMO_TOKEN_PASSWORD' $ZZ_ENV"

    section "User and permissions"
    check "runpod user exists"            "id runpod"
    check "home owned by runpod"          "[[ \$(stat -c %U /home/runpod) == runpod ]]"
    check "sudoers drop-in scoped to apt" "grep -qF 'NOPASSWD: /usr/bin/apt-get, /usr/bin/apt' /etc/sudoers.d/runpod"
    check "sudoers drop-in mode 0440"     "[[ \$(stat -c %a /etc/sudoers.d/runpod) == 440 ]]"

    section "SSH setup"
    if [[ -r /root/.ssh/authorized_keys ]]; then
        local KEY_COUNT UNIQ_COUNT kt
        KEY_COUNT=$(wc -l < /root/.ssh/authorized_keys)
        UNIQ_COUNT=$(sort -u /root/.ssh/authorized_keys | wc -l)
        check "authorized_keys non-empty"     "[[ $KEY_COUNT -ge 1 ]]"
        check "authorized_keys no duplicates" "[[ $KEY_COUNT -eq $UNIQ_COUNT ]]"
        check "/run/sshd exists"              "test -d /run/sshd"
        for kt in rsa ecdsa ed25519; do
            check "host key $kt"              "test -r /etc/ssh/ssh_host_${kt}_key"
        done
    else
        echo "  (skipped — no /root/.ssh/authorized_keys; PUBLIC_KEY was not provided)"
    fi

    section "Sandbox isolation"
    # Verify the isolation property directly: the runpod user's uv tool envs
    # (where huggingface_hub and ty live) must not appear on the sandbox's
    # sys.path. Asserting absence of specific packages was brittle — any
    # notebook can legitimately declare numpy/huggingface_hub/etc. in its
    # PEP 723 header, at which point it ships into the sandbox venv's own
    # site-packages by design.
    local SBX_VENV PY
    SBX_VENV=$(ls -dt /tmp/marimo-sandbox-*/venv 2>/dev/null | head -1 || true)
    if [[ -n "$SBX_VENV" ]]; then
        PY="$SBX_VENV/bin/python"
        check "sandbox venv python exists"     "test -x $PY"
        check "sandbox sys.prefix is the venv" "[[ \$($PY -c 'import sys; print(sys.prefix)') == $SBX_VENV ]]"
        check "marimo importable in sandbox"   "$PY -c 'import marimo'"
        check "no uv tool env on sandbox sys.path" \
            "$PY -c 'import sys; sys.exit(1 if any(\"/.local/share/uv/tools/\" in p for p in sys.path) else 0)'"
    else
        echo "  (skipped — no /tmp/marimo-sandbox-*/venv yet; open a notebook and rerun)"
    fi
}

summary() {
    section "Summary"
    printf '%d passed, %d failed\n' "$PASS" "$FAIL"
    if (( FAIL > 0 )); then
        printf '\nFailures:\n'
        local f
        for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
        exit 1
    fi
}
