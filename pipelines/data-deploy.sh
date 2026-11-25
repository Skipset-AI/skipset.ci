#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ENVIRONMENT="$(python3 -c "import json,os; print(json.loads(os.environ.get('JOB_INPUTS_JSON','{}')).get('environment','prod'))")"
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPOSITORY="${ECR_REPOSITORY:-skipset-data}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

"$PY" -m pip install -q --upgrade pip
"$PY" -m pip install -q ruff==0.16.* boto3
ruff check .
python -m py_compile $(git ls-files '*.py')
python scripts/check_schedule_states.py --environment "$ENVIRONMENT" --region "$AWS_REGION"

SHA="$(git rev-parse HEAD)"
IMAGE_TAG="$SHA"
CLUSTER="skipset-$ENVIRONMENT"

RUNNING=""
for service in api process outreach detect; do
  TD="$(aws ecs describe-services --cluster "$CLUSTER" --services "skipset-$service-$ENVIRONMENT" \
    --query 'services[0].taskDefinition' --output text 2>/dev/null || true)"
  [ -n "$TD" ] && [ "$TD" != "None" ] || continue
  RUNNING="$(aws ecs describe-task-definition --task-definition "$TD" \
    --query "taskDefinition.containerDefinitions[?contains(image, '$ECR_REPOSITORY')]|[0].image" \
    --output text 2>/dev/null | awk -F: '{print $NF}')"
  [ -n "$RUNNING" ] && break
done
if [[ "$RUNNING" =~ ^[0-9a-f]{40}$ ]] && [ "$RUNNING" != "$SHA" ] && [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
  STATUS="$(gh api "repos/${JOB_REPO}/compare/${RUNNING}...${SHA}" --jq .status 2>/dev/null || echo unknown)"
  echo "$CLUSTER runs ${RUNNING:0:12}; deploy ${SHA:0:12} ($STATUS)"
  if [ "$STATUS" = "behind" ]; then
    echo "Refusing stale deploy: commit is older than what $CLUSTER runs" >&2
    exit 0
  fi
fi

if [ -n "${CODEBUILD_PROJECT:-}" ]; then
  BUILD_ID="$(aws codebuild start-build \
    --project-name "$CODEBUILD_PROJECT" \
    --environment-variables-override name=IMAGE_TAG,value="$IMAGE_TAG",type=PLAINTEXT \
    --source-version "$SHA" \
    --query 'build.id' --output text)"
  echo "CodeBuild $BUILD_ID"
  while true; do
    STATUS="$(aws codebuild batch-get-builds --ids "$BUILD_ID" --query 'builds[0].buildStatus' --output text)"
    case "$STATUS" in
      SUCCEEDED) break ;;
      FAILED|FAULT|STOPPED) echo "CodeBuild failed: $STATUS" >&2; exit 1 ;;
      *) sleep 15 ;;
    esac
  done
else
  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
  IMG="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY"
  docker build -t "$IMG:$IMAGE_TAG" -t "$IMG:latest" .
  docker push "$IMG:$IMAGE_TAG"
  docker push "$IMG:latest"
fi
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
IMAGE="$REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"

REFRESHED=0
for service in api detect process outreach; do
  NAME="skipset-$service-$ENVIRONMENT"
  STATUS="$(aws ecs describe-services --cluster "$CLUSTER" --services "$NAME" --query 'services[0].status' --output text 2>/dev/null || echo MISSING)"
  [ "$STATUS" = "ACTIVE" ] || continue
  CURRENT="$(aws ecs describe-services --cluster "$CLUSTER" --services "$NAME" --query 'services[0].taskDefinition' --output text)"
  aws ecs describe-task-definition --task-definition "$CURRENT" --query 'taskDefinition' --output json \
    | jq --arg img "$IMAGE" --arg repo "$ECR_REPOSITORY" '
        .containerDefinitions |= map(if (.image | contains($repo)) then .image = $img else . end)
        | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)
      ' > /tmp/td-"$service".json
  NEW="$(aws ecs register-task-definition --cli-input-json file:///tmp/td-"$service".json --query 'taskDefinition.taskDefinitionArn' --output text)"
  aws ecs update-service --cluster "$CLUSTER" --service "$NAME" --task-definition "$NEW" >/dev/null
  REFRESHED=$((REFRESHED + 1))
done
[ "$REFRESHED" -gt 0 ] || { echo "no services refreshed" >&2; exit 1; }

if [ "$ENVIRONMENT" = "prod" ]; then
  for _ in {1..12}; do
    curl -fsS "https://api.skipset.ai/healthz" && exit 0
    sleep 10
  done
  exit 1
fi