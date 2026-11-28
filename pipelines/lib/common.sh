#!/usr/bin/env bash
set -euo pipefail

pick_python() {
  for c in python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null; then
      echo "$c"
      return 0
    fi
  done
  return 1
}
PY="$(pick_python)"

: "${JOB_REPO:?JOB_REPO required}"
: "${JOB_REF:?JOB_REF required}"

WORK="${SKIPSET_CI_WORK_ROOT:-/var/lib/skipset-ci/work}"
TMP_ROOT="${SKIPSET_CI_TMP_ROOT:-/var/lib/skipset-ci/tmp}"
mkdir -p "$WORK" "$TMP_ROOT" "$WORK/pip-cache"
export TMPDIR="$TMP_ROOT"
export PIP_CACHE_DIR="$WORK/pip-cache"
export XDG_CACHE_HOME="$WORK/pip-cache"
RUN_DIR="$WORK/job-${JOB_ID:-0}-$$"
mkdir -p "$RUN_DIR"
# Each job clones fresh, so its folder goes when the job ends. Kept folders filled
# the root volume's inodes and every clone failed with "No space left on device".
trap 'cd / && rm -rf "$RUN_DIR"' EXIT
cd "$RUN_DIR"

repo_slug="${JOB_REPO#*/}"
_clone_url="https://github.com/${JOB_REPO}.git"
if [ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]; then
  tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  _clone_url="https://x-access-token:${tok}@github.com/${JOB_REPO}.git"
fi
if [ ! -d "$repo_slug/.git" ]; then
  git clone --depth 1 "$_clone_url" "$repo_slug"
  cd "$repo_slug"
  git fetch --depth 1 origin "$JOB_REF"
else
  cd "$repo_slug"
  git fetch --depth 1 origin "$JOB_REF"
fi
git checkout -qf FETCH_HEAD 2>/dev/null || git checkout -qf "origin/${JOB_REF}"
if [ -n "${JOB_SHA:-}" ]; then
  git checkout -qf "$JOB_SHA" 2>/dev/null || true
fi