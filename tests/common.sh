# shellcheck shell=bash
# Shared helpers and test sections for runpod-marimo smoke tests.
# Sourced by tests/test-cpu.sh and tests/test-gpu.sh.

PASS=0
FAIL=0
FAILURES=()

# check DESC CMD [ARG...]
#
# Runs CMD with its arguments directly — no eval, no string re-parsing.
# Values interpolated by the caller (paths, PIDs, tokens with shell
# metacharacters) arrive as argv entries and can never be re-interpreted
# as shell syntax. Anything that needs a pipeline, negation or comparison
# goes through one of the small predicate helpers below instead of a
# quoted shell fragment.
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  ok   %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf '  FAIL %s\n' "$desc"
        FAIL=$((FAIL + 1))
        FAILURES+=("$desc")
    fi
}

section() { printf '\n== %s ==\n' "$*"; }

# ── Predicate helpers ────────────────────────────────────────────────────────
# Each is a plain command that exits 0/1, so it composes with `check` and
# with each other (`check "..." not output_has -i libcuda ldconfig -p`).

# not CMD...            — invert a command's exit status
not() { ! "$@"; }

# eq A B                — exact string equality
eq() { [[ "$1" == "$2" ]]; }

# has_substr STR SUB    — STR contains SUB literally
has_substr() { [[ "$1" == *"$2"* ]]; }

# has_prefix STR PRE    — STR starts with PRE literally
has_prefix() { [[ "$1" == "$2"* ]]; }

# output_has [GREP-OPTS...] PATTERN CMD...
#   CMD's stdout matches PATTERN (grep -q; leading dash-options are passed
#   to grep, e.g. -i, -w, -E, -F). stderr is dropped.
output_has() {
    local -a opts=()
    while [[ $# -gt 0 && "$1" == -* ]]; do opts+=("$1"); shift; done
    local pattern="$1"; shift
    "$@" 2>/dev/null | grep -q "${opts[@]}" -- "$pattern"
}

# glob_exists GLOB      — at least one path matches GLOB (GLOB is quoted by the caller)
glob_exists() { compgen -G "$1" >/dev/null; }

# http_code URL [CURL-ARGS...] — print the HTTP status for a GET of URL
http_code() {
    local url="$1"; shift
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "$url"
}

# wait_for_health SECONDS — poll /health until 2xx or the deadline passes.
#   Per-attempt --connect-timeout / --max-time cap each curl so a stalled
#   TCP-accepted-but-HTTP-hung server cannot push the total past the deadline.
wait_for_health() {
    local deadline=$(( $(date +%s) + $1 ))
    while [[ $(date +%s) -lt $deadline ]]; do
        curl -sfo /dev/null --connect-timeout 3 --max-time 5 http://localhost:2971/health && return 0
        sleep 5
    done
    return 1
}

# Verify a directory is usable by the runpod user: both the write bit and
# the execute (search) bit are required to create files inside it, so we
# check both. The path is %q-quoted here, once, so special characters
# survive the `su -l -c` re-parse — callers pass it raw.
_probe_dir_as_runpod() {
    local path_q
    path_q=$(printf '%q' "$1")
    su -l runpod -c "test -w $path_q && test -x $path_q"
}

# as_runpod CMD-STRING  — run a shell string as the runpod login user
as_runpod() { su -l runpod -c "$1"; }

# Build a fresh PEP 723 sandbox using only the persistent cache (#116).
# An explicit cache path prevents the launcher's image cache masking a miss.
_offline_sandbox_as_runpod() {
    local cache_q version_q
    cache_q=$(printf '%q' "$1")
    version_q=$(printf '%q' "$2")
    su -l runpod -c "bash -s -- $cache_q $version_q" <<'SANDBOX'
set -euo pipefail
cache=$1
version=$2
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
printf '# /// script\n# dependencies = ["marimo==%s"]\n# ///\n' "$version" > "$tmp/notebook.py"
uv sync --cache-dir "$cache" --script "$tmp/notebook.py" --offline --compile-bytecode
SANDBOX
}

# ancestors_of PID — print the comm of every ancestor of PID up to and
#   including PID 1, nearest first, one per line.
ancestors_of() {
    local pid="$1" ppid
    while [[ "$pid" -gt 1 ]]; do
        ppid=$(ps -o ppid= -p "$pid" | tr -d ' ')
        [[ -n "$ppid" ]] || return 1
        # procps prints a bare name; BSD ps prints a path. Normalize.
        basename "$(ps -o comm= -p "$ppid" | tr -d ' ')"
        pid=$ppid
    done
}

# version_major_ge N CMD... — first "vX.Y.Z"/"X.Y.Z" in CMD's output has major >= N
version_major_ge() {
    local min="$1"; shift
    local out major
    out=$("$@" 2>/dev/null) || return 1
    major=$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
    [[ -n "$major" && "$major" -ge "$min" ]]
}

shared_tests() {
    section "Environment"
    echo "MARIMO_VERSION: ${MARIMO_VERSION:-<unset>}"

    section "System packages"
    local cmd
    for cmd in uv uvx gh duckdb runpodctl pi opencode jq git curl wget tmux node ssh; do
        check "$cmd on PATH" command -v "$cmd"
    done
    check "sshd binary present"     test -x /usr/sbin/sshd
    check "Ubuntu 24.04 base"       grep -qF 'VERSION_ID="24.04"' /etc/os-release
    check "uv from /usr/local/bin"  eq "$(command -v uv)"  /usr/local/bin/uv
    check "uvx from /usr/local/bin" eq "$(command -v uvx)" /usr/local/bin/uvx
    # Shipped publicly, so each downloaded tool carries its LICENSE, and
    # each is executed (not just found on PATH) as both identities.
    for cmd in gh duckdb runpodctl; do
        check "$cmd LICENSE shipped" test -r "/usr/share/licenses/$cmd/LICENSE"
    done
    for cmd in "gh --version" "duckdb --version" "runpodctl version" "runpodctl --version"; do
        echo "  [$cmd] $($cmd 2>&1 | head -1)"
        # shellcheck disable=SC2086  # $cmd is a fixed "tool flag" pair
        check "$cmd runs as root"   output_has -E '[0-9]+\.[0-9]+\.[0-9]+' $cmd
        check "$cmd runs as runpod" output_has -E '[0-9]+\.[0-9]+\.[0-9]+' as_runpod "$cmd"
    done

    section "Node.js"
    # marimo's LSP bridge (_lsp/index.cjs) is launched with `node`; the ty
    # LSP enabled in marimo.toml is dead without it. The binary comes from
    # the upstream release tarball, not Ubuntu's EOL Node 18 package, and
    # ships alone — no npm, which would be an unpinned package installer.
    check "node from /usr/local/bin"   eq "$(command -v node)" /usr/local/bin/node
    check "node runs"                  node --version
    check "node major version >= 20"   version_major_ge 20 node --version
    check "npm not installed"          not command -v npm
    check "npx not installed"          not command -v npx
    check "node LICENSE shipped"       test -r /usr/share/licenses/node/LICENSE
    check "node runs as runpod"        as_runpod 'node --version'

    section "Python tooling"
    check "uv Python 3.13 installed"          output_has '3\.13' as_runpod 'uv python list --only-installed'
    check "huggingface_hub installed as tool" output_has -i 'huggingface-hub' as_runpod 'uv tool list'
    check "ty installed as tool"              output_has -w 'ty' as_runpod 'uv tool list'
    check "marimo NOT installed as tool"      not output_has -w 'marimo' as_runpod 'uv tool list'

    section "HTTP endpoint"
    # This section runs BEFORE the process checks: its retry loop is the
    # startup barrier. In CI, docker exec launches this suite well under a
    # second after `docker run -d`, so a bare pgrep below would race
    # marimo's launch; once /health answers, the process must exist.
    # /health is served 200 without authentication, so this probe works
    # identically whether token auth is on (default) or disabled.
    # marimo now launches from the image's prewarmed cache, but a runtime
    # MARIMO_VERSION override still downloads before binding :2971 on first
    # boot against an empty persistent cache, and that was observed to take
    # >6 min on a shared host under load. Retry until a ~10-min deadline.
    check "health endpoint 2xx on :2971" wait_for_health 600
    # Verify the auth boundary end-to-end: the API must reject
    # unauthenticated requests and accept the resolved token.
    # --data-urlencode with -G reads the token from the file and
    # URL-encodes it, so user-chosen passwords with special
    # characters survive the round trip.
    check "API rejects unauthenticated requests" \
        eq "$(http_code http://localhost:2971/api/status)" 401
    check "API accepts the resolved token" \
        eq "$(http_code http://localhost:2971/api/status -G --data-urlencode access_token@/home/runpod/.config/marimo/token)" 200

    section "Marimo process"
    local MARIMO_PID MARIMO_USER MARIMO_CMD MARIMO_WS
    MARIMO_PID=$(pgrep -f 'bin/marimo edit' | head -1 || true)
    check "marimo editor running" test -n "$MARIMO_PID"
    if [[ -n "$MARIMO_PID" ]]; then
        MARIMO_USER=$(ps -o user= -p "$MARIMO_PID" | tr -d ' ')
        MARIMO_CMD=$(ps -o args= -p "$MARIMO_PID")
        check "marimo runs as 'runpod'"   eq "$MARIMO_USER" runpod
        check "marimo --sandbox"          has_substr "$MARIMO_CMD" '--sandbox'
        check "marimo --host 0.0.0.0"     has_substr "$MARIMO_CMD" '--host 0.0.0.0'
        check "marimo --port 2971"        has_substr "$MARIMO_CMD" '--port 2971'

        # Shutdown path. start_marimo.sh execs `su -l runpod -c 'cd ... &&
        # exec uvx ...'`. Every process between PID 1 and marimo must
        # forward SIGTERM: su does (util-linux), and uv does (its tool
        # runner spawns the tool and waits, forwarding SIGTERM/SIGINT —
        # uv-command-support/src/child.rs, run_to_completion). A shell
        # does not: a non-interactive bash receiving SIGTERM just exits,
        # orphaning marimo until Docker's SIGKILL deadline — which is what
        # the inner `exec` removes. So the expected tree is
        # su(1) -> uv -> marimo, and the invariant is "no shell in the
        # ancestry", not a particular depth.
        local MARIMO_ANCESTORS
        MARIMO_ANCESTORS=$(ancestors_of "$MARIMO_PID")
        check "PID 1 is tini"                        eq "$(ps -o comm= -p 1 | tr -d ' ')" tini
        check "no shell between PID 1 and marimo"    not grep -qxE 'bash|sh|dash' <<<"$MARIMO_ANCESTORS"
        # The uvx binary execs its sibling uv (`uv tool uvx`), so the
        # parent normally reports as `uv`; accept either name.
        check "marimo's parent is uv"                grep -qxE 'uvx?' <<<"$(head -1 <<<"$MARIMO_ANCESTORS")"

        # Token auth is mandatory; --no-token must never appear. The resolved
        # token travels via --token-password-file (never a bare
        # --token-password flag, which would leak it into `ps`).
        local TOKEN_FILE=/home/runpod/.config/marimo/token
        check "marimo --token-password-file present" has_substr "$MARIMO_CMD" '--token-password-file'
        check "marimo --no-token absent"             not has_substr "$MARIMO_CMD" '--no-token'
        check "token not on the command line"        not has_substr "$MARIMO_CMD" '--token-password '
        check "token file non-empty"                 test -s "$TOKEN_FILE"
        check "token file owned by runpod"           eq "$(stat -c %U "$TOKEN_FILE")" runpod
        check "token file mode 0600"                 eq "$(stat -c %a "$TOKEN_FILE")" 600
        # Resolution order: MARIMO_TOKEN_PASSWORD wins, then
        # JUPYTER_PASSWORD, then a generated token (content unknowable
        # here, so only the two deterministic sources are asserted).
        # Both values are passed as argv, so a password full of shell
        # metacharacters (CI uses `sp3c!al ch@rs&?`) needs no quoting.
        if [[ -n "${MARIMO_TOKEN_PASSWORD:-}" ]]; then
            check "token file matches MARIMO_TOKEN_PASSWORD" \
                eq "$(cat "$TOKEN_FILE")" "$MARIMO_TOKEN_PASSWORD"
        elif [[ -n "${JUPYTER_PASSWORD:-}" ]]; then
            check "token file matches JUPYTER_PASSWORD fallback" \
                eq "$(cat "$TOKEN_FILE")" "$JUPYTER_PASSWORD"
        fi

        # The workspace path is the last positional argument to marimo
        # edit. Read it from /proc/PID/cmdline (NUL-separated, verbatim)
        # rather than `ps -o args`, which reconstructs the command line
        # and can re-quote arguments containing spaces.
        MARIMO_WS=$(tr '\0' '\n' < /proc/"$MARIMO_PID"/cmdline | tail -n 1)
        check "marimo workspace usable by runpod" _probe_dir_as_runpod "$MARIMO_WS"
        if [[ -z "${MARIMO_WORKSPACE:-}" ]]; then
            check "marimo defaults workspace to /workspace" eq "$MARIMO_WS" /workspace
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
        MARIMO_CWD=$(as_runpod "readlink /proc/$MARIMO_PID/cwd" 2>/dev/null || true)
        check "marimo cwd matches workspace" eq "$MARIMO_CWD" "$MARIMO_WS"
    fi

    section "Zombie reaping"
    # The subshell exits at once, orphaning sleep; it is reparented to
    # PID 1, which must wait() on it once it exits.
    local ORPHAN_PID
    ORPHAN_PID=$(bash -c 'sleep 2 >/dev/null 2>&1 & echo $!')
    sleep 4
    check "PID 1 reaps orphaned children" not output_has Z ps -o stat= -p "$ORPHAN_PID"

    section "MCP integration"
    # Regression test for the mcp 2.0.0 break (marimo#10371). The symbols
    # asserted here are the ones marimo imports from mcp at runtime, so they
    # track marimo's API rather than a pinned mcp version: 0.23.x declared an
    # unbounded `mcp>=1.0.0` while importing `streamablehttp_client` and
    # `mcp.server.fastmcp`, both removed in mcp 2.0.0, which is why the image
    # once capped the resolve at `mcp<2`. marimo 0.24.1+ uses the mcp 2.x API
    # (`streamable_http_client`, `MCPServer`) and bounds the dependency itself
    # (`mcp>=2.0.0,<3`), so the cap is gone.
    #
    # Nothing above catches this: marimo starts fine and serves /health, and
    # the failure surfaces only as an ImportError in the logs when the MCP
    # client connects.
    if [[ -n "$MARIMO_PID" ]]; then
        local MARIMO_BIN MARIMO_ENV_PY
        MARIMO_BIN=$(tr '\0' '\n' < /proc/"$MARIMO_PID"/cmdline | head -1)
        MARIMO_ENV_PY="$(dirname "$(dirname "$MARIMO_BIN")")/bin/python"
        check "marimo tool env python exists" test -x "$MARIMO_ENV_PY"
        # #50: the launcher reads the image's prewarmed cache via
        # `uvx --cache-dir`, whatever UV_CACHE_DIR is, so first boot on an
        # empty volume needs no download. Only when MARIMO_VERSION is the
        # prewarmed version; a runtime override resolves into UV_CACHE_DIR.
        local PREWARMED_VERSION=""
        IFS= read -r PREWARMED_VERSION < /usr/local/share/runpod-marimo/prewarmed-marimo-version 2>/dev/null || true
        check "prewarmed marimo version recorded" test -n "$PREWARMED_VERSION"
        if [[ -n "$PREWARMED_VERSION" && "$PREWARMED_VERSION" == "${MARIMO_VERSION:-}" ]]; then
            check "marimo env comes from the prewarmed cache" \
                has_prefix "$MARIMO_BIN" /home/runpod/.cache/uv/
            # A stale cached index made the prewarmed launch need PyPI anyway;
            # the launcher (marimo's parent) must run --offline.
            local LAUNCHER_PID LAUNCHER_ARGS
            LAUNCHER_PID=$(ps -o ppid= -p "$MARIMO_PID" | tr -d ' ')
            LAUNCHER_ARGS=" $(tr '\0' ' ' < /proc/"$LAUNCHER_PID"/cmdline 2>/dev/null) "
            check "prewarmed launcher runs uvx --offline" has_substr "$LAUNCHER_ARGS" ' --offline '
        fi
        check "mcp streamable-http client importable" \
            "$MARIMO_ENV_PY" -c 'from mcp.client.streamable_http import streamable_http_client'
        check "mcp server importable" \
            "$MARIMO_ENV_PY" -c 'from mcp.server import MCPServer'
        check "mcp client importable" \
            "$MARIMO_ENV_PY" -c 'from mcp import Client'
    else
        echo "  (skipped — marimo process not found)"
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
        MARIMO_ENV_UV=$(as_runpod "tr '\0' '\n' < /proc/$MARIMO_PID/environ | sed -n 's/^UV_CACHE_DIR=//p'" 2>/dev/null || true)
        MARIMO_ENV_HF=$(as_runpod "tr '\0' '\n' < /proc/$MARIMO_PID/environ | sed -n 's/^HF_HOME=//p'" 2>/dev/null || true)
        check "marimo has UV_CACHE_DIR set" test -n "$MARIMO_ENV_UV"
        check "marimo has HF_HOME set"      test -n "$MARIMO_ENV_HF"
        if [[ -n "$MARIMO_ENV_UV" ]]; then
            check "UV_CACHE_DIR usable by runpod" _probe_dir_as_runpod "$MARIMO_ENV_UV"
            if [[ ! "$MARIMO_ENV_UV" -ef /home/runpod/.cache/uv ]]; then
                local seeded_version=""
                IFS= read -r seeded_version < /usr/local/share/runpod-marimo/prewarmed-marimo-version 2>/dev/null || true
                local seeded_uv
                seeded_uv=$(uv --version 2>/dev/null | awk '{print $2}')
                check "sandbox cache seed marker exists" \
                    test -f "$MARIMO_ENV_UV/.runpod-marimo-seeded-${seeded_version}-uv${seeded_uv}"
                check "notebook sandbox builds offline from seeded cache" \
                    _offline_sandbox_as_runpod "$MARIMO_ENV_UV" "$seeded_version"
            fi
        fi
        if [[ -n "$MARIMO_ENV_HF" ]]; then
            check "HF_HOME usable by runpod" _probe_dir_as_runpod "$MARIMO_ENV_HF"
        fi
        if [[ -z "${UV_CACHE_DIR:-}" && -z "${HF_HOME:-}" ]]; then
            EXPECTED_CACHE_ROOT="${MARIMO_CACHE_DIR:-$MARIMO_WS/.cache}"
            check "UV_CACHE_DIR defaults to <cache_root>/uv" \
                eq "$MARIMO_ENV_UV" "$EXPECTED_CACHE_ROOT/uv"
            check "HF_HOME defaults to <cache_root>/huggingface" \
                eq "$MARIMO_ENV_HF" "$EXPECTED_CACHE_ROOT/huggingface"
        fi
    fi

    section "Marimo config"
    local MARIMO_TOML=/home/runpod/.config/marimo/marimo.toml
    check "marimo.toml exists"               test -r "$MARIMO_TOML"
    check "marimo.toml: uv manager"          grep -qF 'manager = "uv"' "$MARIMO_TOML"
    check "marimo.toml: ty LSP section"      grep -qF '[language_servers.ty]' "$MARIMO_TOML"
    check "marimo.toml: ty LSP enabled"      grep -qF 'enabled = true' "$MARIMO_TOML"
    check "marimo.toml: mcp marimo preset"   grep -qF 'presets = ["marimo"]' "$MARIMO_TOML"

    section "marimo-pair skill"
    local SKILL_DIR=/opt/agent-skills/marimo-pair
    check "skill payload present"    test -r "$SKILL_DIR/SKILL.md"
    # Upstream ships both scripts 0755; `chmod -R a+rX` in the Dockerfile
    # preserves that (X adds +x only where it already exists, plus dirs),
    # so the exec bit surviving the extract is worth asserting.
    check "execute-code.sh executable"     test -x "$SKILL_DIR/scripts/execute-code.sh"
    check "discover-servers.sh executable" test -x "$SKILL_DIR/scripts/discover-servers.sh"
    check "upstream LICENSE shipped" test -r /usr/share/licenses/marimo-pair/LICENSE
    check "provenance recorded"      grep -q '^marimo-pair v' "$SKILL_DIR/PROVENANCE"

    # Both identities matter: this image sets no USER, so docker exec and
    # the Runpod console give a root shell, while marimo runs as runpod.
    # A skill linked for only one of them is invisible to half the users.
    local skill_home skill_dir_name
    for skill_home in /root /home/runpod; do
        for skill_dir_name in .claude .agents; do
            check "${skill_home}/${skill_dir_name}/skills link resolves" \
                eq "$(readlink -f "${skill_home}/${skill_dir_name}/skills/marimo-pair")" "$SKILL_DIR"
            check "${skill_home}/${skill_dir_name}/skills readable through link" \
                test -r "${skill_home}/${skill_dir_name}/skills/marimo-pair/SKILL.md"
        done
    done
    check "runpod can read its own skill link" \
        as_runpod 'test -r ~/.claude/skills/marimo-pair/SKILL.md'

    # Functional probe. execute-code.sh resolves MARIMO_TOKEN, then hits
    # GET /api/sessions before executing anything, so it exercises the real
    # auth path headlessly. It cannot succeed outright without a notebook
    # open in a browser, and it CAN succeed if someone has one open (this
    # suite also runs against live pods via run-remote.sh) — so accept
    # either, and pin the assertion on the server having been reached with
    # a working token rather than on a single expected message.
    #
    # The auth boundary itself is already covered by the 401/200 checks in
    # the HTTP endpoint section above; this asserts the skill's own script
    # picks up the exported token, which those cannot see.
    local PAIR_OUT=/tmp/marimo-pair-probe.out
    local PAIR_OUT_NOTOKEN=/tmp/marimo-pair-probe-notoken.out
    as_runpod "bash $SKILL_DIR/scripts/execute-code.sh --url http://localhost:2971 -c pass" \
        > "$PAIR_OUT" 2>&1 || true
    check "execute-code.sh authenticates via exported MARIMO_TOKEN" \
        not grep -qF 'Failed to connect' "$PAIR_OUT"
    # Negative control: the same call with the token stripped must not
    # get past auth. Without it, the check above would also pass against
    # a server that required no token at all.
    as_runpod "MARIMO_TOKEN= bash $SKILL_DIR/scripts/execute-code.sh --url http://localhost:2971 -c pass" \
        > "$PAIR_OUT_NOTOKEN" 2>&1 || true
    check "execute-code.sh is rejected without a token" \
        grep -qF 'Failed to connect' "$PAIR_OUT_NOTOKEN"

    section "Coding agents"
    # pi and opencode are pinned standalone release binaries. Both are
    # Bun-compiled; pi's loads themes, assets and a wasm module from
    # alongside the real binary, so it lives under /opt/pi behind a
    # launcher on PATH (the same shape as pi's own installer) rather than
    # being copied into /usr/local/bin on its own. `--version` is the
    # cheapest probe that actually executes each binary, which a bare
    # `command -v` cannot — a tarball with the wrong architecture or a
    # missing dynamic library would still be "on PATH".
    check "pi launcher is a script, not the binary" grep -q '^exec /opt/pi/pi' /usr/local/bin/pi
    check "pi binary present under /opt/pi"         test -x /opt/pi/pi
    check "pi wasm module present"                  test -r /opt/pi/photon_rs_bg.wasm
    check "pi theme directory present"              test -d /opt/pi/theme
    check "pi LICENSE shipped"                      test -r /usr/share/licenses/pi/LICENSE
    check "opencode LICENSE shipped"                test -r /usr/share/licenses/opencode/LICENSE
    # Both identities matter, as with the skill links above: docker exec
    # and the console give root, marimo's terminal gives runpod.
    local agent
    for agent in pi opencode; do
        check "$agent --version runs as root"   output_has -E '[0-9]+\.[0-9]+\.[0-9]+' "$agent" --version
        check "$agent --version runs as runpod" output_has -E '[0-9]+\.[0-9]+\.[0-9]+' as_runpod "$agent --version"
    done

    section "Env forwarding"
    local RE_ENV=/etc/profile.d/runpod-env.sh
    local ZZ_ENV=/etc/profile.d/zz-pod-env.sh
    check "runpod-env.sh exists"                         test -r "$RE_ENV"
    check "runpod-env.sh exports UV path"                grep -qF 'export UV=/usr/local/bin/uv' "$RE_ENV"
    check "runpod-env.sh exports MARIMO_VERSION"         grep -q 'export MARIMO_VERSION=' "$RE_ENV"
    check "zz-pod-env.sh exists"                             test -r "$ZZ_ENV"
    check "zz-pod-env.sh does not leak PUBLIC_KEY"            not grep -q '^export PUBLIC_KEY' "$ZZ_ENV"
    check "zz-pod-env.sh does not leak JUPYTER_PASSWORD"      not grep -q '^export JUPYTER_PASSWORD' "$ZZ_ENV"
    check "zz-pod-env.sh does not leak MARIMO_TOKEN_PASSWORD" not grep -q '^export MARIMO_TOKEN_PASSWORD' "$ZZ_ENV"
    check "zz-pod-env.sh does not leak MARIMO_DISABLE_AUTH"   not grep -q '^export MARIMO_DISABLE_AUTH' "$ZZ_ENV"

    # MARIMO_TOKEN is deliberately exported (so bundled agent tooling can
    # authenticate), but only the value the Authentication block resolved.
    # An inbound MARIMO_TOKEN is excluded from _forward_env — assert
    # the resolved value, never mere presence, or a stale pod-supplied
    # token would satisfy the check.
    # Both shell flavours must be covered. /etc/profile.d reaches only login
    # shells, but the Runpod SSH proxy and `docker exec` exec bash directly
    # without one (see the 0.6.0 MOTD removal), so a login-shell-only check
    # would pass while the shell users actually get had no token at all.
    # `bash -ic` is the interactive non-login path; stderr is dropped because
    # bash warns about job control when stdin is not a tty.
    # Captured to files and compared with `cmp`: a token can legitimately
    # contain shell metacharacters (CI exercises `sp3c!al ch@rs&?`) and
    # trailing whitespace that command substitution would strip.
    local TOKFILE=/home/runpod/.config/marimo/token
    local u
    for u in root runpod; do
        # shellcheck disable=SC2016  # $MARIMO_TOKEN must expand in the inner shell
        su -l "$u" -c 'printf %s "$MARIMO_TOKEN"' > "/tmp/tok-login-$u" 2>/dev/null || true
        # shellcheck disable=SC2016  # as above; -i is the interactive non-login path
        su "$u" -c 'bash -ic "printf %s \"\$MARIMO_TOKEN\""' > "/tmp/tok-inter-$u" 2>/dev/null || true
    done
    check "zz-pod-env.sh exports MARIMO_TOKEN" \
        grep -q '^export MARIMO_TOKEN=' "$ZZ_ENV"
    for u in root runpod; do
        check "$u login shell MARIMO_TOKEN matches the token file" \
            cmp -s "/tmp/tok-login-$u" "$TOKFILE"
        check "$u interactive shell MARIMO_TOKEN matches the token file" \
            cmp -s "/tmp/tok-inter-$u" "$TOKFILE"
    done

    # docker exec and the Runpod SSH proxy start non-login shells, which
    # never read /etc/profile.d: the tools must be on the container PATH,
    # and interactive shells must recover the pod's cache locations.
    check "container PATH includes runpod's tool bin" \
        grep -qz '^PATH=.*/home/runpod/\.local/bin' /proc/1/environ
    for u in root runpod; do
        # shellcheck disable=SC2016
        check "$u interactive shell recovers HF_HOME" eq \
            "$(su "$u" -c 'env -u HF_HOME -u UV_CACHE_DIR bash -ic "printf %s \"\$HF_HOME\""' 2>/dev/null)" "$MARIMO_ENV_HF"
        # shellcheck disable=SC2016
        check "$u interactive shell recovers UV_CACHE_DIR" eq \
            "$(su "$u" -c 'env -u HF_HOME -u UV_CACHE_DIR bash -ic "printf %s \"\$UV_CACHE_DIR\""' 2>/dev/null)" "$MARIMO_ENV_UV"
    done

    section "User and permissions"
    check "runpod user exists"            id runpod
    check "home owned by runpod"          eq "$(stat -c %U /home/runpod)" runpod
    check "sudoers drop-in scoped to apt" grep -qF 'NOPASSWD: /usr/bin/apt-get, /usr/bin/apt' /etc/sudoers.d/runpod
    check "sudoers drop-in mode 0440"     eq "$(stat -c %a /etc/sudoers.d/runpod)" 440

    section "SSH setup"
    if [[ -r /root/.ssh/authorized_keys ]]; then
        local KEY_COUNT UNIQ_COUNT kt
        KEY_COUNT=$(wc -l < /root/.ssh/authorized_keys | tr -d ' ')
        UNIQ_COUNT=$(sort -u /root/.ssh/authorized_keys | wc -l | tr -d ' ')
        check "authorized_keys non-empty"     test "$KEY_COUNT" -ge 1
        check "authorized_keys no duplicates" test "$KEY_COUNT" -eq "$UNIQ_COUNT"
        check "/run/sshd exists"              test -d /run/sshd
        for kt in rsa ecdsa ed25519; do
            check "host key $kt"              test -r "/etc/ssh/ssh_host_${kt}_key"
        done
    else
        echo "  (no /root/.ssh/authorized_keys; PUBLIC_KEY was not provided)"
        # Host keys are generated per pod by start_marimo.sh when PUBLIC_KEY
        # is set. Keys baked into the image would be shared by every pod
        # running the same public tag.
        check "no SSH host keys baked into the image" not glob_exists '/etc/ssh/ssh_host_*'
    fi

    section "Sandbox isolation"
    # Verify the isolation property directly: the runpod user's uv tool envs
    # (where huggingface_hub and ty live) must not appear on the sandbox's
    # sys.path. Asserting absence of specific packages was brittle — any
    # notebook can legitimately declare numpy/huggingface_hub/etc. in its
    # PEP 723 header, at which point it ships into the sandbox venv's own
    # site-packages by design.
    local SBX_VENV PY
    # shellcheck disable=SC2012  # mtime sort is the point; the glob is a fixed /tmp pattern
    SBX_VENV=$(ls -dt /tmp/marimo-sandbox-*/venv 2>/dev/null | head -1 || true)
    if [[ -n "$SBX_VENV" ]]; then
        PY="$SBX_VENV/bin/python"
        check "sandbox venv python exists"     test -x "$PY"
        check "sandbox sys.prefix is the venv" eq "$("$PY" -c 'import sys; print(sys.prefix)')" "$SBX_VENV"
        check "marimo importable in sandbox"   "$PY" -c 'import marimo'
        check "no uv tool env on sandbox sys.path" \
            "$PY" -c 'import sys; sys.exit(1 if any("/.local/share/uv/tools/" in p for p in sys.path) else 0)'
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
