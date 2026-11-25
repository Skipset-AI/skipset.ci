#!/usr/bin/env bash
# Provision Skipset CI on AWS (profile: skipset). Idempotent where possible.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-skipset}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT=042470865474
CERT_ARN="arn:aws:acm:us-east-1:042470865474:certificate/9a5fb45b-f2fe-4617-be9d-5f3eb00426a4"
VPC=vpc-06df7b2ce083f07d5
PUB_A=subnet-03ee68ede3775fb46
PUB_B=subnet-063cf09d33dfa3421
PRIV_A=subnet-0a5b480feddd9f7c0

HOOK_SECRET="${SKIPSET_CI_HOOK_SECRET:-$(openssl rand -hex 24)}"
GH_WEBHOOK_SECRET="${GITHUB_WEBHOOK_SECRET:-$(openssl rand -hex 16)}"

echo "Ensuring Secrets Manager entries..."
for pair in "skipset/skipset-ci-hook-secret:$HOOK_SECRET" "skipset/skipset-ci-url:https://ci.skipset.ai"; do
  name="${pair%%:*}"
  val="${pair#*:}"
  if aws secretsmanager describe-secret --secret-id "$name" &>/dev/null; then
    aws secretsmanager put-secret-value --secret-id "$name" --secret-string "$val"
  else
    aws secretsmanager create-secret --name "$name" --secret-string "$val"
  fi
done

ROLE=skipset-ci-instance
if ! aws iam get-role --role-name "$ROLE" &>/dev/null; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }'
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
  for pol in cfn-deploy cfn-describe-stacks cfn-template-staging; do
    doc=$(aws iam get-role-policy --role-name skipset-data-github-deploy --policy-name "$pol" --query PolicyDocument --output json)
    aws iam put-role-policy --role-name "$ROLE" --policy-name "$pol" --policy-document "$doc"
  done
  simfix=$(aws iam get-role-policy --role-name skipset-data-github-simfix --policy-name SimFix --query PolicyDocument --output json 2>/dev/null || \
    aws iam get-role-policy --role-name skipset-data-github-simfix --policy-name simfix --query PolicyDocument --output json)
  aws iam put-role-policy --role-name "$ROLE" --policy-name simfix --policy-document "$simfix"
fi
aws iam create-instance-profile --instance-profile-name "$ROLE" 2>/dev/null || true
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" 2>/dev/null || true

echo "Deploy complete hook secret (store for GitHub webhooks): webhook=$GH_WEBHOOK_SECRET"
echo "CI API secret: $HOOK_SECRET"
echo "Next: run launch-ec2-alb.sh or update stack manually"