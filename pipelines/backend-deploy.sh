#!/usr/bin/env bash
# Deploys skipset.backend (Amplify Gen 2) for JOB_REF = main | dev.
# backend.ts reads the per-branch settings below at synth time, so a deploy
# without them silently ships dev-like config (data relays to localhost, no
# Stripe IDs, SSM_ENV=dev). The guard refuses that before anything deploys.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

export BUN_INSTALL="${BUN_INSTALL:-/opt/skipset-ci/bun}"
export PATH="$BUN_INSTALL/bin:$PATH"
: "${AMPLIFY_APP_ID:?AMPLIFY_APP_ID required}"
: "${BACKEND_DEPLOY_ROLE_ARN:?BACKEND_DEPLOY_ROLE_ARN required}"

case "$JOB_REF" in
  main)
    export SKIPSET_DATA_URL="https://api.skipset.ai"
    export APP_URL="https://app.skipset.ai"
    export LEAD_ACTIVITY_BACKFILLED="true"
    export SKIP_LEAD_SEARCH_DOMAIN="false"
    export SSM_ENV="prod"
    export STRIPE_PRICE_PLATFORM="price_1TwOU8BOdyqzKi7oGGP05YWW"
    export STRIPE_PRODUCT_TERRITORY="prod_UwH21RdCnkG5Aa"
    export STRIPE_EVENTBRIDGE_SOURCE="aws.partner/stripe.com/ed_61V5mTSBhSSJKkR6L16V5P9r32SQD9xsFSRQQ3B7Q9LM"
    ;;
  dev)
    # Dev has no data API: relays stay on backend.ts's localhost fallback.
    unset SKIPSET_DATA_URL
    export APP_URL="https://dev.skipset.ai"
    export LEAD_ACTIVITY_BACKFILLED="false"
    export SKIP_LEAD_SEARCH_DOMAIN="true"
    export SSM_ENV="dev"
    export STRIPE_PRICE_PLATFORM="price_1TwMlIBOdyqzKi7oZobwmEom"
    export STRIPE_PRODUCT_TERRITORY="prod_UwFFSVTEixWGcz"
    export STRIPE_EVENTBRIDGE_SOURCE="aws.partner/stripe.com/ed_test_61V5lDvK11p9F7j7y16V5P9r32SQquQKmRbVGHV9EFZg"
    ;;
  *)
    echo "backend-deploy: only main and dev deploy (got $JOB_REF)" >&2
    exit 1
    ;;
esac
export TRIAL_DAYS="14"
# Same value the data API reads (db/secrets_loader.py maps skipset/internal).
INTERNAL_SHARED_SECRET="$(aws secretsmanager get-secret-value --secret-id skipset/internal \
  --region "${AWS_REGION:-us-east-1}" --query SecretString --output text)"
export INTERNAL_SHARED_SECRET

missing=()
[ -n "$INTERNAL_SHARED_SECRET" ] || missing+=(INTERNAL_SHARED_SECRET)
[ -n "$APP_URL" ] || missing+=(APP_URL)
[ -n "$STRIPE_PRICE_PLATFORM" ] || missing+=(STRIPE_PRICE_PLATFORM)
[ -n "$STRIPE_PRODUCT_TERRITORY" ] || missing+=(STRIPE_PRODUCT_TERRITORY)
[ -n "$STRIPE_EVENTBRIDGE_SOURCE" ] || missing+=(STRIPE_EVENTBRIDGE_SOURCE)
if [ "$JOB_REF" = "main" ]; then
  case "${SKIPSET_DATA_URL:-}" in https://*) ;; *) missing+=(SKIPSET_DATA_URL) ;; esac
  [ "$SSM_ENV" = "prod" ] || missing+=(SSM_ENV)
fi
if [ "${#missing[@]}" -gt 0 ]; then
  echo "backend-deploy: refusing to deploy $JOB_REF, bad settings: ${missing[*]}" >&2
  exit 1
fi

bun install --frozen-lockfile
npx tsc --noEmit
bun test

# The instance role only assumes the deploy role; Amplify/CDK rights live there.
creds="$(aws sts assume-role --role-arn "$BACKEND_DEPLOY_ROLE_ARN" \
  --role-session-name "skipset-ci-backend-${JOB_ID:-0}" --duration-seconds 3600 \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)"
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$creds"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

HASH_BEFORE="$(sha256sum amplify_outputs.json 2>/dev/null | awk '{print $1}' || echo none)"

npm_config_user_agent=npm npx ampx pipeline-deploy --branch "$JOB_REF" --app-id "$AMPLIFY_APP_ID"
npm_config_user_agent=npm npx ampx generate outputs --branch "$JOB_REF" --app-id "$AMPLIFY_APP_ID" --out-dir .
HASH_AFTER="$(sha256sum amplify_outputs.json | awk '{print $1}')"
bash scripts/post-deploy.sh amplify_outputs.json

if [ "$JOB_REF" = "dev" ] && [ "$HASH_BEFORE" != "$HASH_AFTER" ]; then
  curl -fsS -X POST "${SKIPSET_CI_URL:-https://ci.skipset.co}/v1/jobs/web-sync" \
    -H "Authorization: Bearer ${SKIPSET_CI_HOOK_SECRET}" \
    -H "X-Skipset-Repo: Skipset-AI/skipset.web" \
    -H "Content-Type: application/json" \
    -d "{\"ref\":\"dev\",\"inputs\":{\"branch\":\"dev\"},\"coalesce\":true}" || true
fi
