#!/usr/bin/env bash
# Run the runpod-marimo smoke tests against a live pod over SSH.
#
# Usage: tests/run-remote.sh <ssh-target> [cpu|gpu]
#
# Example:
#     tests/run-remote.sh user@ssh.runpod.io
#     tests/run-remote.sh user@ssh.runpod.io cpu
#
# For pods that need a specific identity file or other ssh options, put
# them in ~/.ssh/config — e.g.:
#
#     Host *.runpod.io
#         IdentityFile ~/.ssh/id_ed25519
#
# Why this script exists: Runpod's ssh.runpod.io proxy rejects `scp` (no
# sftp subsystem) and inline command exec — it only forwards interactive
# shells. So we ship tests/ as a base64 tarball through a PTY and run the
# suite there.

set -euo pipefail

usage() { echo "usage: $0 <ssh-target> [cpu|gpu]" >&2; exit 2; }
[[ $# -ge 1 && $# -le 2 ]] || usage

TARGET="$1"
VARIANT="${2:-gpu}"
case "$VARIANT" in cpu|gpu) ;; *) usage ;; esac

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$HERE")
TGZ=$(mktemp)
trap 'rm -f "$TGZ"' EXIT
tar -czf "$TGZ" -C "$REPO" tests

{
    echo "set +H"
    echo "base64 -d > /tmp/runpod-marimo-tests.tgz << '__B64_EOF__'"
    base64 < "$TGZ" | fold -w 76
    echo "__B64_EOF__"
    echo "rm -rf /tmp/tests && tar -xzf /tmp/runpod-marimo-tests.tgz -C /tmp/ && bash /tmp/tests/test-${VARIANT}.sh"
    echo "exit"
} | ssh -o StrictHostKeyChecking=accept-new -tt "$TARGET"
