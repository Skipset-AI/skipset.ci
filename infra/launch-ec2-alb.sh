#!/usr/bin/env bash
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-skipset}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
CERT_ARN="arn:aws:acm:us-east-1:042470865474:certificate/9a5fb45b-f2fe-4617-be9d-5f3eb00426a4"
VPC=vpc-06df7b2ce083f07d5
PUB_A=subnet-03ee68ede3775fb46
PUB_B=subnet-063cf09d33dfa3421
PRIV_A=subnet-0a5b480feddd9f7c0

HOOK=$(aws secretsmanager get-secret-value --secret-id skipset/skipset-ci-hook-secret --query SecretString --output text)
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)

ALB_SG=$(aws ec2 create-security-group --group-name skipset-ci-alb --description "Skipset CI ALB" --vpc-id "$VPC" --query GroupId --output text 2>/dev/null || \
  aws ec2 describe-security-groups --filters Name=group-name,Values=skipset-ci-alb --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0 2>/dev/null || true

CI_SG=$(aws ec2 create-security-group --group-name skipset-ci-ec2 --description "Skipset CI EC2" --vpc-id "$VPC" --query GroupId --output text 2>/dev/null || \
  aws ec2 describe-security-groups --filters Name=group-name,Values=skipset-ci-ec2 --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$CI_SG" --protocol tcp --port 8765 --source-group "$ALB_SG" 2>/dev/null || true

TG_ARN=$(aws elbv2 describe-target-groups --names skipset-ci-ctrl --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")
if [ "$TG_ARN" = "None" ] || [ -z "$TG_ARN" ]; then
  TG_ARN=$(aws elbv2 create-target-group --name skipset-ci-ctrl --protocol HTTP --port 8765 --vpc-id "$VPC" --target-type instance --health-check-path /healthz --query TargetGroups[0].TargetGroupArn --output text)
fi

ALB_ARN=$(aws elbv2 describe-load-balancers --names skipset-ci --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
if [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer --name skipset-ci --subnets "$PUB_A" "$PUB_B" --security-groups "$ALB_SG" --query LoadBalancers[0].LoadBalancerArn --output text)
fi
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)

if ! aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`443`]' --output text | grep -q HTTPS; then
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTPS --port 443 --certificates CertificateArn="$CERT_ARN" \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN"
fi

USERDATA=$(cat <<EOF
#!/bin/bash
set -euo pipefail
dnf install -y git python3.11 python3.11-pip python3.11-devel gcc gcc-c++ make docker jq nodejs20 nodejs20-npm unzip
alternatives --install /usr/bin/node node /usr/bin/node-20 20 || true
alternatives --install /usr/bin/npm npm /usr/bin/npm-20 20 || true
alternatives --install /usr/bin/npx npx /usr/bin/npx-20 20 || true
curl -fsSL https://bun.sh/install | BUN_INSTALL=/opt/skipset-ci/bun bash -s bun-v1.3.5
systemctl enable --now docker
mkdir -p /opt/skipset-ci /var/lib/skipset-ci /var/log/skipset-ci /etc/skipset-ci
git clone https://github.com/Skipset-AI/skipset.ci.git /opt/skipset-ci/app
python3.11 -m venv /opt/skipset-ci/venv
/opt/skipset-ci/venv/bin/pip install -r /opt/skipset-ci/app/requirements.txt
HOOK=\$(aws secretsmanager get-secret-value --secret-id skipset/skipset-ci-hook-secret --region us-east-1 --query SecretString --output text)
GH=\$(aws secretsmanager get-secret-value --secret-id skipset/github-sim --region us-east-1 --query SecretString --output text 2>/dev/null || echo "")
WH=\$(aws secretsmanager get-secret-value --secret-id skipset/github-webhook-ci --region us-east-1 --query SecretString --output text)
cat > /etc/skipset-ci/env <<ENV
SKIPSET_CI_DB=/var/lib/skipset-ci/jobs.sqlite3
SKIPSET_CI_LOG_DIR=/var/log/skipset-ci
SKIPSET_CI_HOOK_SECRET=\$HOOK
SKIPSET_CI_PUBLIC_URL=https://ci.skipset.co
GITHUB_WEBHOOK_SECRET=\$WH
GITHUB_TOKEN=\$GH
GITHUB_SIM_TOKEN=\$GH
AWS_REGION=us-east-1
HOME=/root
BUN_INSTALL=/opt/skipset-ci/bun
AMPLIFY_APP_ID=d3qwoijyp09jpi
BACKEND_DEPLOY_ROLE_ARN=arn:aws:iam::042470865474:role/skipset-backend-deploy
SKIPSET_CI_URL=https://ci.skipset.co
ENV
cp /opt/skipset-ci/app/systemd/skipset-ci.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now skipset-ci
EOF
)

IID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=skipset-ci-controller Name=instance-state-name,Values=running,pending --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo None)
if [ "$IID" = "None" ] || [ -z "$IID" ]; then
  IID=$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.medium --iam-instance-profile Name=skipset-ci-instance \
    --subnet-id "$PRIV_A" --security-group-ids "$CI_SG" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=skipset-ci-controller}]' \
    --user-data "$USERDATA" \
    --query Instances[0].InstanceId --output text)
  echo "Launched instance $IID"
  aws ec2 wait instance-running --instance-ids "$IID"
fi

aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets Id="$IID",Port=8765
aws secretsmanager put-secret-value --secret-id skipset/skipset-ci-url --secret-string "https://ci.skipset.co"

echo "ALB DNS: $ALB_DNS"
echo "Add DNS: ci.skipset.co CNAME -> $ALB_DNS"
echo "Instance: $IID"