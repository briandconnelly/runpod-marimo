#!/usr/bin/env bash
# Smoke tests for a running runpod-marimo GPU pod.
#
# Run inside the pod as root:
#     bash tests/test-gpu.sh
#
# Or from a workstation:
#     scp -r tests <pod>:/tmp/ && ssh <pod> bash /tmp/tests/test-gpu.sh
#
# Tests that require image rebuilds or pod restarts (hook behavior, image
# labels) are not covered here — those belong in CI or manual release
# validation.

set -u

# Keep in sync with the major version in CUDA_BASE_TAG (Dockerfile).
EXPECTED_CUDA_MAJOR=12

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

echo "variant: gpu"
shared_tests

section "GPU variant"
check "nvtop present"                 "command -v nvtop"
check "libcuda present"               "ldconfig -p | grep -q libcuda.so"
check "libcudart present"             "ldconfig -p | grep -q libcudart.so"
check "libcudart major v$EXPECTED_CUDA_MAJOR" "ldconfig -p | grep -qE 'libcudart\\.so\\.${EXPECTED_CUDA_MAJOR}(\\.|$| )'"

section "GPU device nodes"
check "/dev/nvidia[N] present"  "ls /dev/nvidia[0-9]* >/dev/null 2>&1"
check "/dev/nvidiactl present"  "test -c /dev/nvidiactl"
check "/dev/nvidia-uvm present" "test -c /dev/nvidia-uvm"

section "GPU container env (from PID 1)"
check "CUDA_VERSION set"               "grep -qz '^CUDA_VERSION=' /proc/1/environ"
check "NVIDIA_VISIBLE_DEVICES set"     "grep -qz '^NVIDIA_VISIBLE_DEVICES=' /proc/1/environ"
check "NVIDIA_DRIVER_CAPABILITIES set" "grep -qz '^NVIDIA_DRIVER_CAPABILITIES=' /proc/1/environ"

section "GPU functional"
check "nvidia-smi runs"             "nvidia-smi -L"
check "nvidia-smi lists a GPU"      "nvidia-smi -L | grep -q '^GPU '"
check "runpod user can nvidia-smi"  "su -l runpod -c 'nvidia-smi -L' | grep -q '^GPU '"

SBX_VENV=$(ls -dt /tmp/marimo-sandbox-*/venv 2>/dev/null | head -1 || true)
if [[ -n "$SBX_VENV" ]]; then
    PY="$SBX_VENV/bin/python"
    check "libcuda.so.1 loadable via ctypes" "$PY -c 'import ctypes; ctypes.CDLL(\"libcuda.so.1\")'"
    check "libcudart loadable via ctypes"    "$PY -c 'import ctypes.util, ctypes; n=ctypes.util.find_library(\"cudart\"); assert n; ctypes.CDLL(n)'"
    check "cuInit(0) succeeds"               "$PY -c 'import ctypes; cuda=ctypes.CDLL(\"libcuda.so.1\"); rc=cuda.cuInit(0); assert rc==0, rc'"
    check "cuDeviceGetCount >= 1"            "$PY -c 'import ctypes; cuda=ctypes.CDLL(\"libcuda.so.1\"); cuda.cuInit(0); n=ctypes.c_int(); rc=cuda.cuDeviceGetCount(ctypes.byref(n)); assert rc==0 and n.value>=1, (rc,n.value)'"
else
    echo "  (ctypes CUDA load / cuInit checks skipped — no sandbox venv; open a notebook and rerun)"
fi

summary
