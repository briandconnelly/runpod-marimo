#!/usr/bin/env bash
# Recompute the pinned SHA256 for every checksum-verified download in the
# Dockerfile.
#
# Renovate bumps the *_VERSION ARGs but cannot recompute the matching
# *_SHA256 ARG: its regex custom manager only extracts dependency metadata,
# and postUpgradeTasks is gated behind allowedCommands, which is self-hosted
# only. So every such bump lands with a stale checksum and dies on the
# Dockerfile's `sha256sum -c`. CI runs this to repair those PRs in place.
#
#   sync-checksums.sh --check        verify only; exit 1 if any pin is stale
#   sync-checksums.sh                rewrite stale pins in the Dockerfile
#   sync-checksums.sh --base <ref>   refuse to rewrite a pin whose version is
#                                    unchanged since <ref>
#
# --base is the safety interlock. A stale checksum on a version that this PR
# did not touch does not mean "Renovate forgot the SHA" - it means the bytes
# behind an already-pinned tag changed, i.e. upstream re-tagged a release or
# something worse. Silently re-pinning that would launder a supply-chain
# change into a routine green build, so it is a hard failure instead.
#
# Nothing below is hardcoded per tool. Every `ARG <PREFIX>_SHA256=` in the
# Dockerfile is paired with its `ARG <PREFIX>_VERSION=`, and the download URL
# is read back out of the RUN line that references that version, so adding a
# fourth checksummed tool needs no change here.

set -Eeuo pipefail

cd "$(dirname "$0")/.."

check_only=false
base_ref=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --check) check_only=true; shift ;;
        --base) base_ref=${2:?--base needs a git ref}; shift 2 ;;
        *) echo "usage: $0 [--check] [--base <ref>]" >&2; exit 2 ;;
    esac
done

# sha256sum on Linux/CI, shasum on macOS.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

arg_value() {
    sed -n "s/^ARG $1=//p" Dockerfile | head -1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

stale=0
checked=0
mutated=0

while read -r prefix; do
    ver_arg="${prefix}_VERSION"
    sha_arg="${prefix}_SHA256"

    version=$(arg_value "$ver_arg")
    pinned=$(arg_value "$sha_arg")

    if [[ -z $version || -z $pinned ]]; then
        echo "error: $prefix is missing $ver_arg or $sha_arg" >&2
        exit 1
    fi

    # Recover the URL template from the RUN line that consumes this version,
    # rather than duplicating it here where it could silently drift.
    url_tpl=$(grep -F "\${${ver_arg}}" Dockerfile | grep -oE 'https://[^"]+' | head -1)
    if [[ -z $url_tpl ]]; then
        echo "error: no download URL in Dockerfile referencing \${$ver_arg}" >&2
        exit 1
    fi

    # Expand ${VER#v} before ${VER} so the longer form wins. Plain parameter
    # expansion, never eval, so Dockerfile text is data and not code.
    url=${url_tpl//\$\{${ver_arg}#v\}/${version#v}}
    url=${url//\$\{${ver_arg}\}/${version}}

    # shellcheck disable=SC2016  # matching a literal "${", not expanding it
    if [[ $url == *'${'* ]]; then
        echo "error: unresolved placeholder in URL for $prefix: $url" >&2
        exit 1
    fi

    echo "==> $prefix $version"
    echo "    $url"

    curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$tmp/artifact"
    actual=$(sha256_of "$tmp/artifact")

    checked=$((checked + 1))

    if [[ $actual == "$pinned" ]]; then
        echo "    ok  $actual"
        continue
    fi

    stale=$((stale + 1))
    echo "    STALE"
    echo "      pinned: $pinned"
    echo "      actual: $actual"

    # Interlock: same version as the base branch, but different bytes.
    if [[ -n $base_ref ]]; then
        base_version=$(git show "${base_ref}:Dockerfile" 2>/dev/null |
            sed -n "s/^ARG ${ver_arg}=//p" | head -1 || true)
        if [[ -n $base_version && $base_version == "$version" ]]; then
            echo "    REFUSING TO AUTO-UPDATE" >&2
            echo "      $ver_arg is $version on both this branch and $base_ref," >&2
            echo "      yet the published bytes no longer match the pinned checksum." >&2
            echo "      That is upstream mutating a released tag, not a missed bump." >&2
            echo "      Investigate before touching $sha_arg." >&2
            mutated=$((mutated + 1))
            continue
        fi
    fi

    if [[ $check_only == false ]]; then
        # In-place edit via temp file; macOS and GNU sed disagree about -i.
        sed "s|^ARG ${sha_arg}=.*|ARG ${sha_arg}=${actual}|" Dockerfile >"$tmp/Dockerfile.new"
        mv "$tmp/Dockerfile.new" Dockerfile
        echo "    updated $sha_arg"
    fi
done < <(sed -n 's/^ARG \([A-Z0-9_]*\)_SHA256=.*/\1/p' Dockerfile)

if [[ $checked -eq 0 ]]; then
    echo "error: no *_SHA256 ARGs found in Dockerfile - the discovery regex is broken" >&2
    exit 1
fi

echo
echo "checked $checked pinned download(s), $stale stale, $mutated refused"

if [[ $mutated -gt 0 ]]; then
    echo "refusing to proceed: released bytes changed under an unchanged version" >&2
    exit 1
fi

if [[ $stale -gt 0 && $check_only == true ]]; then
    echo "run scripts/sync-checksums.sh to fix" >&2
    exit 1
fi
