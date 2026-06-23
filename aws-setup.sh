#!/bin/bash
set -euo pipefail

# =============================================================================
# AWS ECS Bootstrap Script
# Sets up ECR, ECS Cluster, OIDC provider, and IAM role for GitHub Actions
# Usage: bash aws-setup.sh
# =============================================================================

# ── Config ────────────────────────────────────────────────────────────────────
AWS_REGION="us-east-1"
APP_NAME="enterprise-gh-app"
GITHUB_REPO="devopsbyraham/githubactions-new-project"
IAM_ROLE_NAME="GitHubActionsECSRole"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
divider() { echo -e "\n──────────────────────────────────────────"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
divider
info "Checking prerequisites..."
command -v aws  >/dev/null 2>&1 || error "aws CLI not found. Install: https://aws.amazon.com/cli/"
command -v jq   >/dev/null 2>&1 || error "jq not found. Install: brew install jq  /  apt install jq"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
    || error "AWS CLI not authenticated. Run: aws configure"

info "Account ID : $AWS_ACCOUNT_ID"
info "Region     : $AWS_REGION"
info "App name   : $APP_NAME"
info "GitHub repo: $GITHUB_REPO"

# ── Step 1: ECR Repository ────────────────────────────────────────────────────
divider
info "Step 1/6 — Creating ECR repository..."

if aws ecr describe-repositories --repository-names "$APP_NAME" --region "$AWS_REGION" &>/dev/null; then
    warn "ECR repository '$APP_NAME' already exists — skipping."
else
    aws ecr create-repository \
        --repository-name "$APP_NAME" \
        --image-scanning-configuration scanOnPush=true \
        --region "$AWS_REGION" > /dev/null
    info "ECR repository created."
fi

ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$APP_NAME"
info "ECR URI: $ECR_URI"

# ── Step 2: ECS Fargate Cluster ───────────────────────────────────────────────
divider
info "Step 2/6 — Creating ECS Fargate cluster..."

CLUSTER_STATUS=$(aws ecs describe-clusters \
    --clusters "${APP_NAME}-cluster" \
    --region "$AWS_REGION" \
    --query "clusters[0].status" \
    --output text 2>/dev/null || echo "MISSING")

if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
    warn "ECS cluster '${APP_NAME}-cluster' already exists — skipping."
else
    aws ecs create-cluster \
        --cluster-name "${APP_NAME}-cluster" \
        --region "$AWS_REGION" > /dev/null
    info "ECS cluster created."
fi

# ── Step 3: CloudWatch Log Group ──────────────────────────────────────────────
divider
info "Step 3/6 — Creating CloudWatch log group..."

if aws logs describe-log-groups \
    --log-group-name-prefix "/ecs/$APP_NAME" \
    --region "$AWS_REGION" \
    --query "logGroups[0].logGroupName" \
    --output text 2>/dev/null | grep -q "$APP_NAME"; then
    warn "Log group '/ecs/$APP_NAME' already exists — skipping."
else
    aws logs create-log-group \
        --log-group-name "/ecs/$APP_NAME" \
        --region "$AWS_REGION"
    info "CloudWatch log group created."
fi

# ── Step 4: GitHub OIDC Provider ──────────────────────────────────────────────
divider
info "Step 4/6 — Registering GitHub OIDC provider in AWS IAM..."

OIDC_URL="https://token.actions.githubusercontent.com"
EXISTING_PROVIDER=$(aws iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?ends_with(Arn, 'token.actions.githubusercontent.com')].Arn" \
    --output text 2>/dev/null)

if [ -n "$EXISTING_PROVIDER" ]; then
    warn "GitHub OIDC provider already registered — skipping."
else
    aws iam create-open-id-connect-provider \
        --url "$OIDC_URL" \
        --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" \
        --client-id-list "sts.amazonaws.com" > /dev/null
    info "OIDC provider registered."
fi

# ── Step 5: IAM Role for GitHub Actions ───────────────────────────────────────
divider
info "Step 5/6 — Creating IAM role '$IAM_ROLE_NAME'..."

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:*"
        },
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

if aws iam get-role --role-name "$IAM_ROLE_NAME" &>/dev/null; then
    warn "IAM role '$IAM_ROLE_NAME' already exists — skipping creation."
else
    aws iam create-role \
        --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" > /dev/null

    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess

    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

    info "IAM role created and policies attached."
fi

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

# ── Step 6: Patch task-definition.json ────────────────────────────────────────
divider
info "Step 6/6 — Patching task-definition.json with your AWS Account ID..."

TASK_DEF_FILE="$(dirname "$0")/task-definition.json"

if [ ! -f "$TASK_DEF_FILE" ]; then
    warn "task-definition.json not found at $TASK_DEF_FILE — skipping patch."
else
    # Replace placeholder with real account ID
    sed -i.bak "s/<YOUR_AWS_ACCOUNT_ID>/$AWS_ACCOUNT_ID/g" "$TASK_DEF_FILE"
    rm -f "${TASK_DEF_FILE}.bak"
    info "task-definition.json patched."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
divider
echo -e "\n${GREEN}✓ AWS setup complete!${NC}\n"
echo "  ECR URI    : $ECR_URI"
echo "  ECS Cluster: ${APP_NAME}-cluster"
echo "  IAM Role   : $ROLE_ARN"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Add this secret to GitHub → Settings → Secrets → Actions:"
echo "     Name : AWS_ROLE_ARN"
echo "     Value: $ROLE_ARN"
echo ""
echo "  2. Create GitHub Environment:"
echo "     Settings → Environments → New environment → name: production"
echo ""
echo "  3. Push to main — the pipeline will register the ECS Task Definition."
echo ""
echo "  4. Then create the ECS Service manually (one-time) in the AWS Console:"
echo "     ECS → Clusters → ${APP_NAME}-cluster → Create Service"
echo "     Task Definition : enterprise-gh-app-task (latest)"
echo "     Service name    : enterprise-gh-app-service"
echo "     Desired tasks   : 1"
echo "     Security Group  : Allow inbound TCP port 80"
echo "     Auto-assign IP  : ENABLED"
echo ""
echo "  5. Push to main again — full pipeline will deploy to ECS."
divider
