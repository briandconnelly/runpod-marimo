#!/usr/bin/env bash
# Run every CI smoke-test suite against a local image.
#
#     tests/ci-suites.sh runpod-marimo:smoke-test
#
# This is CI's smoke-test job, runnable on any machine with Docker. Each
# suite starts a container with different startup inputs and runs
# tests/test-cpu.sh inside it; the refusal suites assert that startup stops
# with the documented error. Exits non-zero if any check fails.

set -u

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <image>" >&2
    exit 2
fi
IMAGE=$1

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

TMP=$(mktemp -d)
trap 'docker rm -f marimo-ci >/dev/null 2>&1; rm -rf -- "$TMP"' EXIT

group()    { if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::group::$*"; else section "$*"; fi; }
endgroup() { if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::endgroup::"; fi; }

# run_suite_raw NAME DOCKER-RUN-ARGS... — start a container, run the
# in-container suite, then the host-side checks the EXPECT_* variables ask
# for. run_suite adds the ephemeral-cache override most suites use.
run_suite_raw() {
    local name="$1"; shift
    group "smoke: $name"
    docker rm -f marimo-ci >/dev/null 2>&1
    docker run -d --name marimo-ci "$@" \
        -v "$SCRIPT_DIR:/tests:ro" \
        "$IMAGE" >/dev/null
    # A suite that dies with the container (exit 137) otherwise
    # leaves no trace of why marimo stopped.
    docker exec marimo-ci bash /tests/test-cpu.sh || {
        docker inspect --format 'container: running={{.State.Running}} exit={{.State.ExitCode}} oomkilled={{.State.OOMKilled}}' marimo-ci
        echo "--- docker logs marimo-ci ---"; docker logs marimo-ci 2>&1 | tail -n 100
        exit 1
    }
    docker logs marimo-ci > "$TMP/suite.log" 2>&1
    if [[ "${EXPECT_CHOWN_WARNINGS:-false}" == true ]]; then
        for dir in /workspace /workspace/.cache /workspace/.cache/uv /workspace/.cache/huggingface; do
            check "denied chown warns for $dir" \
                grep -qF "Warning: could not chown '$dir' to runpod;" "$TMP/suite.log"
        done
    fi
    if [[ "${EXPECT_CHMOD_FALLBACK:-false}" == true ]]; then
        for dir in /workspace/.cache /workspace/.cache/uv /workspace/.cache/huggingface; do
            check "denied chown falls back to chmod for $dir" \
                grep -qF "Warning: could not chown '$dir' to runpod; made it world-writable (mode 1777) instead." "$TMP/suite.log"
            check "$dir is mode 1777" eq "$(docker exec marimo-ci stat -c %a "$dir")" 1777
        done
    fi
    if [[ -n "${EXPECT_LOG_LINE:-}" ]]; then
        check "logs contain line: $EXPECT_LOG_LINE" grep -qxF -- "$EXPECT_LOG_LINE" "$TMP/suite.log"
    fi
    if [[ -n "${EXPECT_LOG_TEXT:-}" ]]; then
        check "logs contain: $EXPECT_LOG_TEXT" grep -qF -- "$EXPECT_LOG_TEXT" "$TMP/suite.log"
    fi
    if [[ -n "${EXPECT_EXEC:-}" ]]; then
        check "docker exec: $EXPECT_EXEC" docker exec marimo-ci bash -c "$EXPECT_EXEC"
    fi
    if [[ "${EXPECT_CLEAN_STOP:-false}" == true ]]; then
        # SIGTERM must reach marimo through PID 1. 137 means Docker gave up
        # waiting and sent SIGKILL.
        docker stop -t 30 marimo-ci >/dev/null
        check "container stops without SIGKILL" \
            not eq "$(docker inspect -f '{{.State.ExitCode}}' marimo-ci)" 137
    fi
    docker rm -f marimo-ci >/dev/null
    endgroup
}
run_suite() {
    local name="$1"; shift
    run_suite_raw "$name" -e MARIMO_CACHE_DIR=/home/runpod/.cache "$@"
}

# exit_code_within SECONDS — print the marimo-ci container's exit code once
#   it has stopped, or nothing if it is still running at the deadline.
#   Polls `docker inspect` rather than wrapping `docker wait` in GNU
#   `timeout`, which stock macOS does not ship.
exit_code_within() {
    local deadline=$(( $(date +%s) + $1 ))
    while [[ $(date +%s) -lt $deadline ]]; do
        if [[ "$(docker inspect -f '{{.State.Running}}' marimo-ci 2>/dev/null)" == false ]]; then
            docker inspect -f '{{.State.ExitCode}}' marimo-ci
            return 0
        fi
        sleep 1
    done
}

# expect_refusal NAME EXPECTED-TEXT DOCKER-RUN-ARGS... — startup must exit 1
# and log EXPECTED-TEXT.
expect_refusal() {
    local name="$1" text="$2"; shift 2
    group "refusal: $name"
    docker rm -f marimo-ci >/dev/null 2>&1
    docker run -d --name marimo-ci "$@" "$IMAGE" >/dev/null
    check "$name: exits 1" eq "$(exit_code_within 60)" 1
    docker logs marimo-ci > "$TMP/refusal.log" 2>&1
    check "$name: reports why" grep -qF -- "$text" "$TMP/refusal.log"
    docker rm -f marimo-ci >/dev/null
    endgroup
}

# ── Token resolution ─────────────────────────────────────────────────────────
# One suite run per auth mode: the smoke tests assert different things
# depending on MARIMO_TOKEN_PASSWORD / JUPYTER_PASSWORD, so each branch of
# the startup script's token resolution gets exercised against a real
# container. The default suite also checks that a stop reaches marimo.
EXPECT_CLEAN_STOP=true run_suite "default (generated token)"
# Also pins the URL-encoded proxy link printed to the pod logs.
EXPECT_LOG_LINE='Access marimo at: https://testpod-2971.proxy.runpod.net/?access_token=sp3c%21al%20ch%40rs%26%3F' \
    run_suite "explicit password wins over JUPYTER_PASSWORD" \
    -e 'MARIMO_TOKEN_PASSWORD=sp3c!al ch@rs&?' -e JUPYTER_PASSWORD=from-jupyter \
    -e RUNPOD_POD_ID=testpod
run_suite "JUPYTER_PASSWORD fallback" -e JUPYTER_PASSWORD=from-jupyter
# An inbound MARIMO_TOKEN must never survive into the shell
# environment, where it would shadow the resolved token.
run_suite "inbound MARIMO_TOKEN does not shadow the resolved one" \
    -e MARIMO_TOKEN=poisoned-inbound-value
# Existing templates still carry the old documented default
# MARIMO_DISABLE_AUTH=false; it must boot normally with auth on.
run_suite "legacy MARIMO_DISABLE_AUTH=false keeps auth on" \
    -e MARIMO_DISABLE_AUTH=false
# Running without a token is not possible: the removed opt-out
# must stop the pod rather than start marimo unauthenticated.
expect_refusal "MARIMO_DISABLE_AUTH=true" "Error: MARIMO_DISABLE_AUTH is no longer supported" \
    -e MARIMO_DISABLE_AUTH=true -e MARIMO_CACHE_DIR=/home/runpod/.cache

# ── Caches and volumes ───────────────────────────────────────────────────────
# #50: the default cache root is <workspace>/.cache, so an empty
# /workspace stands in for a freshly attached network volume. With
# no network at all, marimo must still start from the image's
# prewarmed cache. #116: the suite also requires a seed marker and
# builds a notebook sandbox offline from the persistent cache.
run_suite_raw "first boot on an empty persistent cache, no network" \
    --network none
# #115: dropping CHOWN produces real EPERM errors. umask 000
# leaves new root-owned dirs usable by runpod. Supplementary
# runpod membership lets root install the root:runpod env file
# without CHOWN; the token file is created as runpod, so auth
# stays on.
EXPECT_CHOWN_WARNINGS=true run_suite_raw "denied chown, writable caches" \
    --cap-drop CHOWN --group-add runpod --tmpfs /workspace:mode=1777 \
    --entrypoint /tests/start-no-chown.sh
# With the normal umask, new directories come out root-owned 0755,
# as on Runpod's NFS pod volumes. Startup must chmod them 1777 so
# marimo still starts on the first boot.
EXPECT_CHOWN_WARNINGS=true EXPECT_CHMOD_FALLBACK=true \
    run_suite_raw "denied chown, umask 022 (NFS-like) caches" \
    --cap-drop CHOWN --group-add runpod --tmpfs /workspace:mode=1777 \
    --entrypoint /tests/start-no-chown.sh -e TEST_UMASK=022
# A pre-existing cache directory runpod cannot write is left alone,
# so it must reach the probe's clear error on the first boot rather
# than dying at the chown, which is what made each restart create
# one more directory.
expect_refusal "unwritable cache" \
    "Error: UV_CACHE_DIR '/workspace/.cache/uv' is not writable by the runpod user." \
    --cap-drop CHOWN --tmpfs /workspace:mode=1777 --entrypoint /tests/start-no-chown.sh \
    -e TEST_UMASK=022 -e TEST_PRECREATE_UNWRITABLE=/workspace/.cache/uv \
    -v "$SCRIPT_DIR:/tests:ro"
check "unwritable cache: chown denial is not itself fatal" \
    not grep -qF "Error: failed to chown" "$TMP/refusal.log"

# ── Path validation ──────────────────────────────────────────────────────────
expect_refusal "MARIMO_WORKSPACE under /etc" "refuses to take ownership" \
    -e MARIMO_WORKSPACE=/etc/foo -e MARIMO_CACHE_DIR=/home/runpod/.cache
expect_refusal "relative MARIMO_WORKSPACE" "must be a non-empty absolute path" \
    -e MARIMO_WORKSPACE=relative/path -e MARIMO_CACHE_DIR=/home/runpod/.cache
run_suite "MARIMO_WORKSPACE=/data/notebooks" -e MARIMO_WORKSPACE=/data/notebooks

# ── Startup hooks ────────────────────────────────────────────────────────────
printf '#!/bin/bash\ntouch /tmp/pre-start-ran\n' > "$TMP/pre_ok.sh"
printf '#!/bin/bash\nexit 1\n' > "$TMP/fail.sh"
chmod 755 "$TMP"/*.sh
EXPECT_LOG_TEXT="Warning: /post_start.sh failed" EXPECT_EXEC="test -f /tmp/pre-start-ran" \
    run_suite "pre_start runs; failing post_start only warns" \
    -v "$TMP/pre_ok.sh:/pre_start.sh:ro" -v "$TMP/fail.sh:/post_start.sh:ro"
expect_refusal "failing pre_start" "Error: /pre_start.sh failed; aborting startup." \
    -v "$TMP/fail.sh:/pre_start.sh:ro" -e MARIMO_CACHE_DIR=/home/runpod/.cache

# ── SSH ──────────────────────────────────────────────────────────────────────
# Two newline-separated keys, as Runpod sends every key on the account.
ssh-keygen -q -t ed25519 -N '' -f "$TMP/id_a"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/id_b"
chmod 644 "$TMP/id_a"   # mounted read-only; copied to a 0600 root-owned file for ssh
EXPECT_EXEC="install -m 600 /k /tmp/k && ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i /tmp/k root@localhost true" \
    run_suite "PUBLIC_KEY starts sshd and authorizes every key" \
    -e "PUBLIC_KEY=$(cat "$TMP/id_b.pub")"$'\n'"$(cat "$TMP/id_a.pub")" \
    -v "$TMP/id_a:/k:ro"

# ── Version override ─────────────────────────────────────────────────────────
# A runtime MARIMO_VERSION other than the prewarmed one downloads (network
# on, default persistent cache) and still passes the full suite.
EXPECT_LOG_TEXT="differs from the prewarmed" \
    run_suite_raw "MARIMO_VERSION override" -e MARIMO_VERSION=0.25.1

summary
