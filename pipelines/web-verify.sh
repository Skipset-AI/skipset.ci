#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export PATH="$BUN_INSTALL/bin:$PATH"
BRANCH="${JOB_REF:-dev}"
BACKEND_BRANCH="$(python3 -c "import json,os; print(json.loads(os.environ.get('JOB_INPUTS_JSON','{}')).get('branch',os.environ.get('JOB_REF','dev')))")"

bun install --frozen-lockfile
AMPLIFY_APP_ID="${AMPLIFY_APP_ID:-}" BACKEND_BRANCH="$BACKEND_BRANCH" bun run sync-outputs || true
GH_TOKEN="${GH_TOKEN:-${REPO_ACCESS_TOKEN:-}}" BACKEND_BRANCH="$BACKEND_BRANCH" bun run sync-schema || bun run sync-schema:local || true
bun run typecheck
bun run test