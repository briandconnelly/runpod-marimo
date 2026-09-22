#!/usr/bin/env bash
# Enforce Runpod's length cap on the pod-template READMEs.
#
# README-gpu.md and README-cpu.md are pasted into a Runpod pod template's
# description field, which is capped at 5000 characters. Nothing in the
# image build would notice an over-length README, so check it here.
#
# The cap is measured in bytes, not characters: a UTF-8 byte count is always
# >= the character count, so passing this check passes the real limit no
# matter how Runpod counts. That makes the check conservative for text with
# em dashes or other multi-byte punctuation, which these READMEs use freely.
#
#   check-readme-length.sh              check the default template READMEs
#   check-readme-length.sh FILE...      check the named files instead

set -euo pipefail

readonly MAX_BYTES=5000

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  cd "$(dirname "$0")/.."
  files=(README-gpu.md README-cpu.md)
fi

status=0
for f in "${files[@]}"; do
  bytes=$(wc -c <"$f" | tr -d ' ')
  if [ "$bytes" -gt "$MAX_BYTES" ]; then
    printf '%s: %s bytes — %s over Runpod%s %s-byte limit\n' \
      "$f" "$bytes" "$((bytes - MAX_BYTES))" "'s" "$MAX_BYTES" >&2
    status=1
  else
    printf '%s: %s bytes (%s to spare)\n' "$f" "$bytes" "$((MAX_BYTES - bytes))"
  fi
done

exit "$status"
