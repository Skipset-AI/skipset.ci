#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export PATH="$BUN_INSTALL/bin:$PATH"
bun install --frozen-lockfile

HASH_BEFORE="$(sha256sum amplify_outputs.json 2>/dev/null | awk '{print $1}' || echo none)"

npm_config_user_agent=npm npx ampx pipeline-deploy --branch "$JOB_REF" --app-id "${AMPLIFY_APP_ID:?}"
npm_config_user_agent=npm npx ampx generate outputs --branch "$JOB_REF" --app-id "$AMPLIFY_APP_ID" --out-dir .
HASH_AFTER="$(sha256sum amplify_outputs.json | awk '{print $1}')"
bash scripts/post-deploy.sh amplify_outputs.json

if [ "$JOB_REF" = "dev" ] && [ "$HASH_BEFORE" != "$HASH_AFTER" ]; then
  curl -fsS -X POST "${SKIPSET_CI_URL}/v1/jobs/web-sync" \
    -H "Authorization: Bearer ${SKIPSET_CI_HOOK_SECRET}" \
    -H "X-Skipset-Repo: Skipset-AI/skipset.web" \
    -H "Content-Type: application/json" \
    -d "{\"ref\":\"dev\",\"inputs\":{\"branch\":\"dev\"},\"coalesce\":true}" || true
fi