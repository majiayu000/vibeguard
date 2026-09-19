#!/usr/bin/env bash
set -euo pipefail
if (($# != 2)); then
  echo "Usage: bash scripts/ci/verify_release_source.sh <event-sha> <tag-name>" >&2
  exit 2
fi
release_commit="$(git rev-parse --verify --end-of-options "$1^{commit}")"
if [[ "$(git rev-parse HEAD)" != "$release_commit" ]]; then
  echo "Release checkout does not match the triggering commit." >&2
  exit 1
fi
tag_commit="$(git rev-parse --verify --end-of-options "refs/tags/$2^{commit}")"
if [[ "$tag_commit" != "$release_commit" ]]; then
  echo "Release tag does not match the triggering commit." >&2
  exit 1
fi
if git merge-base --is-ancestor "$release_commit" refs/remotes/origin/main; then
  echo "OK: release commit is reachable from origin/main"
else
  result=$?
  if ((result == 1)); then
    echo "Release commit is not reachable from origin/main." >&2
  else
    echo "Could not verify release ancestry; main history must be available." >&2
  fi
  exit "$result"
fi
