#!/bin/bash
# CI entrypoint: with CAP_CHOWN dropped, TEST_UMASK sets the mode of newly
# created root-owned cache directories: 000 behaves like Runpod's MooseFS
# volumes (0777), 022 like its NFS volumes (0755, needing the chmod fallback).
set -Eeuo pipefail
umask "${TEST_UMASK:-000}"
# A pre-existing directory that runpod cannot write: startup leaves
# existing directories' ownership and mode alone, so the probe must fail.
if [[ -n "${TEST_PRECREATE_UNWRITABLE:-}" ]]; then
    mkdir -p "$TEST_PRECREATE_UNWRITABLE"
    chmod 0755 "$TEST_PRECREATE_UNWRITABLE"
fi
exec /start_marimo.sh
