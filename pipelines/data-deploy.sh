#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ENVIRONMENT="$(python3 -c "import json,os; print(json.loads(os.environ.get('JOB_INPUTS_JSON','{}')).get('environment','prod'))")"
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPOSITORY="${ECR_REPOSITORY:-skipset-data}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

pip install -q ruff==0.16.*
ruff check .
python -m py_compile $(git ls-files '*.py')

SHA="$(git rev-parse HEAD)"
IMAGE_TAG="$SHA"

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
  docker build -t "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:$IMAGE_TAG" .
  docker push "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:$IMAGE_TAG"
fi

CLUSTER="skipset-$ENVIRONMENT"
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