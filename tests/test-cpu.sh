#!/usr/bin/env bash
# Smoke tests for a running runpod-marimo CPU pod.
#
# Run inside the pod as root:
#     bash tests/test-cpu.sh
#
# Or from a workstation:
#     scp -r tests <pod>:/tmp/ && ssh <pod> bash /tmp/tests/test-cpu.sh
#
# Tests that require image rebuilds or pod restarts (hook behavior, image
# labels) are not covered here — those belong in CI or manual release
# validation.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

echo "variant: cpu"
shared_tests

section "CPU variant"
check "nvtop absent"     "! command -v nvtop"
check "CUDA libs absent" "! ldconfig -p | grep -qi libcuda"

summary
