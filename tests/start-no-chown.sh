#!/bin/bash
# CI entrypoint: with CAP_CHOWN dropped, mkdir's umask determines whether
# runpod can use newly created root-owned cache directories.
set -Eeuo pipefail
umask "${TEST_UMASK:-000}"
exec /start_marimo.sh
