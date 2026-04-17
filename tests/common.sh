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
    local MARIMO_PID MARIMO_USER MARIMO_CMD
    MARIMO_PID=$(pgrep -f 'bin/marimo edit' | head -1 || true)
    check "marimo editor running" "test -n '$MARIMO_PID'"
    if [[ -n "$MARIMO_PID" ]]; then
        MARIMO_USER=$(ps -o user= -p "$MARIMO_PID" | tr -d ' ')
        MARIMO_CMD=$(ps -o args= -p "$MARIMO_PID")
        check "marimo runs as 'runpod'"   "[[ '$MARIMO_USER' == runpod ]]"
        check "marimo --sandbox"          "[[ '$MARIMO_CMD' == *--sandbox* ]]"
        check "marimo --host 0.0.0.0"     "[[ '$MARIMO_CMD' == *'--host 0.0.0.0'* ]]"
        check "marimo --port 2971"        "[[ '$MARIMO_CMD' == *'--port 2971'* ]]"
        # Token auth: exactly one of --no-token or --token-password must be
        # present, matching whether the pod was launched with
        # MARIMO_TOKEN_PASSWORD set.
        if [[ "$MARIMO_CMD" == *--token-password* ]]; then
            check "marimo --token-password (auth enabled)"     "[[ '$MARIMO_CMD' == *--token-password* ]]"
            check "marimo NOT --no-token (mutually exclusive)" "[[ '$MARIMO_CMD' != *--no-token* ]]"
        else
            check "marimo --no-token (auth disabled, default)" "[[ '$MARIMO_CMD' == *--no-token* ]]"
        fi
    fi

    section "HTTP endpoint"
    check "health endpoint 2xx on :2971" "curl -sfo /dev/null http://localhost:2971/"

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
    check "zz-pod-env.sh does not leak PUBLIC_KEY"           "! grep -q '^export PUBLIC_KEY' $ZZ_ENV"
    check "zz-pod-env.sh does not leak JUPYTER_PASSWORD"     "! grep -q '^export JUPYTER_PASSWORD' $ZZ_ENV"
    check "zz-pod-env.sh does not leak MARIMO_TOKEN_PASSWORD" "! grep -q '^export MARIMO_TOKEN_PASSWORD' $ZZ_ENV"

    section "MOTD"
    check "/etc/motd exists and non-empty"       "test -s /etc/motd"
    check "/etc/motd has banner glyphs"          "grep -qF '_/_/' /etc/motd"
    check "/etc/motd has separator line"         "grep -qFe '------' /etc/motd"
    check "/etc/profile.d/motd.sh exists"        "test -r /etc/profile.d/motd.sh"
    check "profile.d hook cats /etc/motd"        "grep -qF '/etc/motd' /etc/profile.d/motd.sh"
    check "profile.d hook skips SSH sessions"    "grep -qF 'SSH_CONNECTION' /etc/profile.d/motd.sh"

    section "User and permissions"
    check "runpod user exists"            "id runpod"
    check "home owned by runpod"          "[[ \$(stat -c %U /home/runpod) == runpod ]]"
    check "workspace exists"              "test -d /home/runpod/workspace"
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
    local SBX_VENV PY
    SBX_VENV=$(ls -dt /tmp/marimo-sandbox-*/venv 2>/dev/null | head -1 || true)
    if [[ -n "$SBX_VENV" ]]; then
        PY="$SBX_VENV/bin/python"
        check "sandbox venv python exists"     "test -x $PY"
        check "sandbox sys.prefix is the venv" "[[ \$($PY -c 'import sys; print(sys.prefix)') == $SBX_VENV ]]"
        check "marimo importable in sandbox"   "$PY -c 'import marimo'"
        check "huggingface_hub NOT in sandbox" "! $PY -c 'import huggingface_hub'"
        check "ty NOT in sandbox"              "! $PY -c 'import ty'"
        check "numpy NOT in sandbox"           "! $PY -c 'import numpy'"
        check "torch NOT in sandbox"           "! $PY -c 'import torch'"
        check "pandas NOT in sandbox"          "! $PY -c 'import pandas'"
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
