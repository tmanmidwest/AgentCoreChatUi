#!/bin/bash
# =============================================================================
# deploy.sh — agentcore-chat ECS Fargate Deployment
# =============================================================================
# Usage:  ./deploy.sh
# Requires: AWS CLI v2, Docker Desktop, Node.js, Git
#
# Deploys the agentcore-chat React frontend + Node.js backend to AWS Fargate.
# Prompts for all required configuration (Agent ARN, AWS creds, app name, etc.)
# Builds and pushes the container to ECR, creates EFS, ALB, and ECS service.
# =============================================================================

set -euo pipefail

# ── FIXED CONFIGURATION ───────────────────────────────────────────────────────
APP_NAME="agentcore-chat"
GITHUB_REPO="https://github.com/tmanmidwest/agentcore-chat.git"   # ← update this when you push to GitHub
CONTAINER_PORT=3001
CPU=512        # 0.5 vCPU  (backend is heavier than a static app)
MEMORY=1024    # 1 GB
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

CHECKMARK="${GREEN}✔${NC}"
ARROW="${BLUE}▶${NC}"
WARNING="${YELLOW}⚠${NC}"

STATE_FILE=".agentcore-chat-state"

log()     { echo -e "${ARROW}  $1"; }
success() { echo -e "${CHECKMARK}  $1"; }
warn()    { echo -e "${WARNING}  ${YELLOW}$1${NC}"; }
error()   { echo -e "${RED}✖  ERROR: $1${NC}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }

wait_for() {
  local description="$1"
  local check_cmd="$2"
  local expected="$3"
  local max_attempts="${4:-30}"
  local attempt=0
  log "Waiting for $description..."
  while [ $attempt -lt $max_attempts ]; do
    result=$(eval "$check_cmd" 2>/dev/null || echo "")
    if echo "$result" | grep -q "$expected"; then
      success "$description is ready"
      return 0
    fi
    sleep 5
    attempt=$((attempt + 1))
    echo -n "."
  done
  echo ""
  error "Timed out waiting for $description"
}

# ── PRE-FLIGHT CHECKS ─────────────────────────────────────────────────────────
header "Pre-flight checks"

command -v aws >/dev/null 2>&1    || error "AWS CLI not found. Install from https://aws.amazon.com/cli/"
command -v docker >/dev/null 2>&1 || error "Docker not found. Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
command -v node >/dev/null 2>&1   || error "Node.js not found. Install from https://nodejs.org/"
command -v git >/dev/null 2>&1    || error "Git not found. Install from https://git-scm.com/"

docker info >/dev/null 2>&1 || error "Docker is not running. Please start Docker Desktop and try again."
success "All required tools found and running"

CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session and try again."

ACCOUNT_ID=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
SESSION_USER=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'].split('/')[-1])")
success "Logged in as: $SESSION_USER (Account: $ACCOUNT_ID)"

# ── REGION SELECTION ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Select an AWS region to deploy to:${NC}"
echo ""
echo -e "  ${BOLD} 1)${NC} us-east-1       US East (N. Virginia)      ${YELLOW}— most services, lowest cost${NC}"
echo -e "  ${BOLD} 2)${NC} us-east-2       US East (Ohio)"
echo -e "  ${BOLD} 3)${NC} us-west-1       US West (N. California)"
echo -e "  ${BOLD} 4)${NC} us-west-2       US West (Oregon)"
echo -e "  ${BOLD} 5)${NC} eu-west-1       Europe (Ireland)"
echo -e "  ${BOLD} 6)${NC} eu-west-2       Europe (London)"
echo -e "  ${BOLD} 7)${NC} eu-west-3       Europe (Paris)"
echo -e "  ${BOLD} 8)${NC} eu-central-1    Europe (Frankfurt)"
echo -e "  ${BOLD} 9)${NC} eu-north-1      Europe (Stockholm)"
echo -e "  ${BOLD}10)${NC} ap-southeast-1  Asia Pacific (Singapore)"
echo -e "  ${BOLD}11)${NC} ap-southeast-2  Asia Pacific (Sydney)"
echo -e "  ${BOLD}12)${NC} ap-northeast-1  Asia Pacific (Tokyo)"
echo -e "  ${BOLD}13)${NC} ap-northeast-2  Asia Pacific (Seoul)"
echo -e "  ${BOLD}14)${NC} ap-south-1      Asia Pacific (Mumbai)"
echo -e "  ${BOLD}15)${NC} ca-central-1    Canada (Central)"
echo -e "  ${BOLD}16)${NC} sa-east-1       South America (São Paulo)"
echo ""

DEFAULT_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
read -rp "  Enter number or region name [default: $DEFAULT_REGION]: " REGION_INPUT
echo ""

case "$REGION_INPUT" in
  1)  REGION="us-east-1" ;;
  2)  REGION="us-east-2" ;;
  3)  REGION="us-west-1" ;;
  4)  REGION="us-west-2" ;;
  5)  REGION="eu-west-1" ;;
  6)  REGION="eu-west-2" ;;
  7)  REGION="eu-west-3" ;;
  8)  REGION="eu-central-1" ;;
  9)  REGION="eu-north-1" ;;
  10) REGION="ap-southeast-1" ;;
  11) REGION="ap-southeast-2" ;;
  12) REGION="ap-northeast-1" ;;
  13) REGION="ap-northeast-2" ;;
  14) REGION="ap-south-1" ;;
  15) REGION="ca-central-1" ;;
  16) REGION="sa-east-1" ;;
  "")  REGION="$DEFAULT_REGION" ;;
  *)  REGION="$REGION_INPUT" ;;
esac

aws ec2 describe-regions --region-names "$REGION" --query 'Regions[0].RegionName' \
  --output text >/dev/null 2>&1 \
  || error "Invalid or inaccessible region: '$REGION'."
success "Region: $REGION"

# ── AGENT CONFIGURATION ────────────────────────────────────────────────────────
header "Bedrock AgentCore configuration"

echo ""
echo -e "  ${BOLD}These values connect your chat app to your deployed agent.${NC}"
echo -e "  Find them in the AWS console: Bedrock → Agents → your agent → Aliases"
echo ""

# Agent ARN
read -rp "  Agent ARN (arn:aws:bedrock-agentcore:...): " AGENT_ARN
[ -n "$AGENT_ARN" ] || error "Agent ARN is required."
success "Agent ARN: $AGENT_ARN"

# Auto-parse region from ARN if possible
ARN_REGION=$(echo "$AGENT_ARN" | awk -F: '{print $4}')
if [ -n "$ARN_REGION" ] && [ "$ARN_REGION" != "$REGION" ]; then
  warn "Agent ARN is in region '$ARN_REGION' but you are deploying to '$REGION'."
  warn "The backend will call the agent in $ARN_REGION — make sure your AWS credentials allow this."
fi
AGENT_REGION="${ARN_REGION:-$REGION}"

# Agent ID
echo ""
echo -e "  ${BOLD}Agent ID${NC} — the short ID of your agent (not the full ARN)."
echo -e "  Example: ABCDE12345"
read -rp "  Agent ID: " AGENT_ID
[ -n "$AGENT_ID" ] || error "Agent ID is required."
success "Agent ID: $AGENT_ID"

# Agent Alias ID
echo ""
echo -e "  ${BOLD}Agent Alias ID${NC} — the alias ID (not alias name), shown on the Aliases tab."
echo -e "  Example: TSTALIASID or a custom alias ID like BCDEF23456"
read -rp "  Agent Alias ID: " AGENT_ALIAS_ID
[ -n "$AGENT_ALIAS_ID" ] || error "Agent Alias ID is required."
success "Agent Alias ID: $AGENT_ALIAS_ID"

# ── APP DISPLAY NAME ──────────────────────────────────────────────────────────
header "App display name"

echo ""
echo -e "  ${BOLD}What should the chat app be called in the UI?${NC}"
echo -e "  This shows in the sidebar header and browser tab."
echo -e "  Example: Saviynt Support, IT Helpdesk, HR Assistant"
echo ""
read -rp "  App name [default: Agent Chat]: " APP_DISPLAY_NAME
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Agent Chat}"
success "App display name: $APP_DISPLAY_NAME"

# ── AWS CREDENTIALS FOR THE BACKEND ──────────────────────────────────────────
header "AWS credentials for the backend container"

echo ""
echo -e "  The backend needs AWS credentials to call your Bedrock agent."
echo -e "  ${BOLD}Option 1:${NC} IAM Role (recommended if running on ECS — no keys needed)"
echo -e "  ${BOLD}Option 2:${NC} Access keys (simpler for first deploys)"
echo ""
read -rp "  Use IAM Role (no keys)? [Y/n]: " USE_IAM_ROLE
USE_IAM_ROLE="${USE_IAM_ROLE:-Y}"

if [[ "$USE_IAM_ROLE" =~ ^[Yy]$ ]]; then
  AWS_ACCESS_KEY_ID_VAL=""
  AWS_SECRET_ACCESS_KEY_VAL=""
  USE_TASK_ROLE=true
  success "Will use ECS task IAM role for agent access"
  warn "You must create a task role with bedrock:InvokeAgent permission before the app will work."
  warn "See the README for the exact IAM policy to attach."
else
  echo ""
  read -rp "  AWS Access Key ID: " AWS_ACCESS_KEY_ID_VAL
  [ -n "$AWS_ACCESS_KEY_ID_VAL" ] || error "Access Key ID is required when not using IAM role."
  read -rsp "  AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY_VAL
  echo ""
  [ -n "$AWS_SECRET_ACCESS_KEY_VAL" ] || error "Secret Access Key is required."
  USE_TASK_ROLE=false
  success "Access keys accepted (stored as ECS secrets — not in code or state file)"
fi

# ── JWT SECRET ────────────────────────────────────────────────────────────────
header "JWT secret"

echo ""
echo -e "  A random secret used to sign login tokens. Auto-generated if you leave this blank."
read -rp "  JWT secret [leave blank to auto-generate]: " JWT_SECRET_INPUT

if [ -z "$JWT_SECRET_INPUT" ]; then
  JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  success "JWT secret auto-generated"
else
  JWT_SECRET="$JWT_SECRET_INPUT"
  success "JWT secret accepted"
fi

# ── REGISTRATION POLICY ───────────────────────────────────────────────────────
header "User registration"

echo ""
echo -e "  ${BOLD}After the first account is created (first-run), should registration stay open?${NC}"
echo -e "  For an internal IT tool with a small team, 'No' is the right choice."
echo -e "  You can add users manually via the SQLite CLI (see README)."
echo ""
read -rp "  Allow open registration after first user? [y/N]: " ALLOW_REG
ALLOW_REG="${ALLOW_REG:-N}"
if [[ "$ALLOW_REG" =~ ^[Yy]$ ]]; then
  ALLOW_REGISTRATION="true"
  warn "Registration is open — anyone with the URL can create an account."
else
  ALLOW_REGISTRATION="false"
  success "Registration will be locked after first user is created."
fi

# ── CONFIRM ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Deployment summary${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}App name:${NC}          $APP_DISPLAY_NAME"
echo -e "  ${BOLD}Region:${NC}            $REGION"
echo -e "  ${BOLD}AWS account:${NC}       $ACCOUNT_ID"
echo -e "  ${BOLD}Agent ARN:${NC}         $AGENT_ARN"
echo -e "  ${BOLD}Agent ID:${NC}          $AGENT_ID"
echo -e "  ${BOLD}Agent Alias ID:${NC}    $AGENT_ALIAS_ID"
echo -e "  ${BOLD}Agent region:${NC}      $AGENT_REGION"
echo -e "  ${BOLD}IAM role auth:${NC}     $USE_TASK_ROLE"
echo -e "  ${BOLD}Open registration:${NC} $ALLOW_REGISTRATION"
echo ""
read -rp "  Continue with deployment? [Y/n]: " CONFIRM_DEPLOY
CONFIRM_DEPLOY="${CONFIRM_DEPLOY:-Y}"
[[ "$CONFIRM_DEPLOY" =~ ^[Yy]$ ]] || { echo "Aborted. Nothing was created."; exit 0; }

if [ -f "$STATE_FILE" ]; then
  warn "A previous deployment state file exists ($STATE_FILE)."
  warn "This suggests the app may already be deployed in this directory."
  read -rp "  Continue anyway and overwrite? [y/N]: " CONFIRM_OVERWRITE
  [[ "$CONFIRM_OVERWRITE" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ── NETWORKING ────────────────────────────────────────────────────────────────
header "Networking"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' \
  --output text --region "$REGION")
[ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ] && error "No default VPC found. Please create one in the AWS console."
success "Default VPC: $VPC_ID"

SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[*].SubnetId' \
  --output text --region "$REGION" | tr '\t' '\n' | head -2 | tr '\n' ' ' | xargs)
SUBNET_COUNT=$(echo "$SUBNET_IDS" | wc -w | xargs)
[ "$SUBNET_COUNT" -lt 2 ] && error "Need at least 2 subnets in your default VPC. Found: $SUBNET_COUNT"
SUBNET_1=$(echo "$SUBNET_IDS" | awk '{print $1}')
SUBNET_2=$(echo "$SUBNET_IDS" | awk '{print $2}')
success "Subnets: $SUBNET_1, $SUBNET_2"

# ── SECURITY GROUPS ───────────────────────────────────────────────────────────
header "Security groups"

log "Creating ALB security group (or reusing if it exists)..."
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="${APP_NAME}-alb-sg" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$ALB_SG_ID" ] || [ "$ALB_SG_ID" = "None" ]; then
  ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name "${APP_NAME}-alb-sg" \
    --description "AgentCore Chat ALB - HTTP from internet" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id "$ALB_SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    --region "$REGION" >/dev/null
fi
success "ALB security group: $ALB_SG_ID"

log "Creating ECS task security group (or reusing if it exists)..."
ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="${APP_NAME}-ecs-sg" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$ECS_SG_ID" ] || [ "$ECS_SG_ID" = "None" ]; then
  ECS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${APP_NAME}-ecs-sg" \
    --description "AgentCore Chat ECS task - traffic from ALB only" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id "$ECS_SG_ID" \
    --protocol tcp --port $CONTAINER_PORT \
    --source-group "$ALB_SG_ID" \
    --region "$REGION" >/dev/null
  aws ec2 authorize-security-group-ingress \
    --group-id "$ECS_SG_ID" \
    --protocol tcp --port 2049 \
    --source-group "$ECS_SG_ID" \
    --region "$REGION" >/dev/null
fi
success "ECS task security group: $ECS_SG_ID"

# ── EFS (PERSISTENT STORAGE FOR SQLITE) ───────────────────────────────────────
header "EFS filesystem (SQLite persistent storage)"

log "Creating EFS filesystem (or reusing if it exists)..."
EFS_ID=$(aws efs describe-file-systems \
  --query "FileSystems[?Tags[?Key=='Name'&&Value=='${APP_NAME}-data']].FileSystemId" \
  --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$EFS_ID" ] || [ "$EFS_ID" = "None" ]; then
  EFS_ID=$(aws efs create-file-system \
    --performance-mode generalPurpose \
    --encrypted \
    --tags Key=Name,Value="${APP_NAME}-data" \
    --region "$REGION" \
    --query 'FileSystemId' --output text)
fi
success "EFS filesystem: $EFS_ID"

wait_for "EFS filesystem" \
  "aws efs describe-file-systems --file-system-id $EFS_ID --query 'FileSystems[0].LifeCycleState' --output text --region $REGION" \
  "available"

log "Creating EFS mount targets (or reusing if they exist)..."
MT_COUNT=$(aws efs describe-mount-targets \
  --file-system-id "$EFS_ID" \
  --query 'MountTargets | length(@)' \
  --output text --region "$REGION" 2>/dev/null || echo "0")

if [ "$MT_COUNT" = "0" ]; then
  aws efs create-mount-target \
    --file-system-id "$EFS_ID" \
    --subnet-id "$SUBNET_1" \
    --security-groups "$ECS_SG_ID" \
    --region "$REGION" >/dev/null
  aws efs create-mount-target \
    --file-system-id "$EFS_ID" \
    --subnet-id "$SUBNET_2" \
    --security-groups "$ECS_SG_ID" \
    --region "$REGION" >/dev/null
fi

log "Waiting for EFS mount targets to become available..."
attempt=0
while [ $attempt -lt 40 ]; do
  STATES=$(aws efs describe-mount-targets \
    --file-system-id "$EFS_ID" \
    --query 'MountTargets[*].LifeCycleState' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "")
  TOTAL=$(echo "$STATES" | wc -w | xargs)
  READY=$(echo "$STATES" | tr '\t' '\n' | grep -c "^available$" || true)
  echo -ne "  Mount targets ready: ${READY} / ${TOTAL}\r"
  if [ "$TOTAL" -ge 1 ] && [ "$READY" = "$TOTAL" ]; then
    echo ""
    break
  fi
  sleep 8
  attempt=$((attempt + 1))
done
echo ""
success "EFS mount targets ready"

log "Creating EFS access point..."
ACCESS_POINT_ID=$(aws efs describe-access-points \
  --file-system-id "$EFS_ID" \
  --query 'AccessPoints[0].AccessPointId' \
  --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$ACCESS_POINT_ID" ] || [ "$ACCESS_POINT_ID" = "None" ]; then
  ACCESS_POINT_ID=$(aws efs create-access-point \
    --file-system-id "$EFS_ID" \
    --posix-user Uid=1000,Gid=1000 \
    --root-directory "Path=/data,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=755}" \
    --tags Key=Name,Value="${APP_NAME}-access-point" \
    --region "$REGION" \
    --query 'AccessPointId' --output text)
fi
success "EFS access point: $ACCESS_POINT_ID"

# ── IAM TASK EXECUTION ROLE ───────────────────────────────────────────────────
header "IAM task execution role"

ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole \
  --query 'Role.Arn' --output text 2>/dev/null || true)

if [ -z "$ROLE_ARN" ]; then
  log "Creating ecsTaskExecutionRole..."
  ROLE_ARN=$(aws iam create-role \
    --role-name ecsTaskExecutionRole \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Principal":{"Service":"ecs-tasks.amazonaws.com"},
        "Action":"sts:AssumeRole"
      }]
    }' \
    --query 'Role.Arn' --output text)
  aws iam attach-role-policy \
    --role-name ecsTaskExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  success "Created ecsTaskExecutionRole"
else
  success "ecsTaskExecutionRole already exists"
fi

# ── TASK ROLE (for Bedrock access via IAM role) ───────────────────────────────
TASK_ROLE_ARN=""
if [ "$USE_TASK_ROLE" = "true" ]; then
  header "ECS task role (Bedrock access)"

  TASK_ROLE_NAME="${APP_NAME}-task-role"
  TASK_ROLE_ARN=$(aws iam get-role --role-name "$TASK_ROLE_NAME" \
    --query 'Role.Arn' --output text 2>/dev/null || true)

  if [ -z "$TASK_ROLE_ARN" ]; then
    log "Creating task role with bedrock:InvokeAgent permission..."
    TASK_ROLE_ARN=$(aws iam create-role \
      --role-name "$TASK_ROLE_NAME" \
      --assume-role-policy-document '{
        "Version":"2012-10-17",
        "Statement":[{
          "Effect":"Allow",
          "Principal":{"Service":"ecs-tasks.amazonaws.com"},
          "Action":"sts:AssumeRole"
        }]
      }' \
      --query 'Role.Arn' --output text)

    aws iam put-role-policy \
      --role-name "$TASK_ROLE_NAME" \
      --policy-name "bedrock-invoke-agent" \
      --policy-document "{
        \"Version\":\"2012-10-17\",
        \"Statement\":[{
          \"Effect\":\"Allow\",
          \"Action\":[\"bedrock:InvokeAgent\"],
          \"Resource\":\"${AGENT_ARN}\"
        }]
      }"
    success "Task role created: $TASK_ROLE_ARN"
  else
    success "Task role already exists: $TASK_ROLE_ARN"
  fi
fi

# ── ECS SERVICE-LINKED ROLE ───────────────────────────────────────────────────
header "ECS service-linked role"
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true
success "ECS service-linked role ready"

# ── ECS CLUSTER ───────────────────────────────────────────────────────────────
header "ECS cluster"

aws ecs create-cluster --cluster-name "$APP_NAME" --region "$REGION" >/dev/null 2>/dev/null || true
success "Cluster: $APP_NAME"

# ── CLOUDWATCH LOGS ───────────────────────────────────────────────────────────
header "CloudWatch log group"

LOG_GROUP="/ecs/${APP_NAME}-webapp"
aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$REGION" 2>/dev/null || true
success "Log group: $LOG_GROUP"

# ── ECR + CONTAINER BUILD ─────────────────────────────────────────────────────
header "Building and pushing container image to ECR"

ECR_REPO="${APP_NAME}-webapp"
CONTAINER_IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:latest"

log "Creating ECR repository (or reusing if it exists)..."
EXISTING_REPO=$(aws ecr describe-repositories \
  --repository-names "$ECR_REPO" \
  --region "$REGION" \
  --query 'repositories[0].repositoryUri' \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_REPO" ] || [ "$EXISTING_REPO" = "None" ]; then
  aws ecr create-repository \
    --repository-name "$ECR_REPO" \
    --region "$REGION" >/dev/null
fi
success "ECR repository ready: $CONTAINER_IMAGE"

EXISTING_IMAGE=$(aws ecr describe-images \
  --repository-name "$ECR_REPO" \
  --image-ids imageTag=latest \
  --region "$REGION" \
  --query 'imageDetails[0].imageTags[0]' \
  --output text 2>/dev/null || echo "")

if [ "$EXISTING_IMAGE" = "latest" ]; then
  success "Image already exists in ECR — skipping build"
else
  log "Logging Docker into ECR..."
  aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null
  success "Docker logged into ECR"

  log "Cloning repo from GitHub..."
  BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "$BUILD_DIR"' EXIT
  git clone $GITHUB_REPO "$BUILD_DIR" --depth 1 --quiet
  success "Repo cloned"

  # Inject the frontend env vars into the build
  log "Writing frontend environment config..."
  cat > "$BUILD_DIR/frontend/.env" <<ENVEOF
VITE_APP_NAME=${APP_DISPLAY_NAME}
VITE_API_URL=
ENVEOF

  log "Building Docker image (this takes 3-5 minutes)..."
  docker buildx build --platform linux/amd64 --push -t "${CONTAINER_IMAGE}" "$BUILD_DIR"
  rm -rf "$BUILD_DIR"
  trap - EXIT
  success "Image built and pushed to ECR: $CONTAINER_IMAGE"
fi

# ── SECRETS MANAGER (for sensitive env vars) ──────────────────────────────────
header "Storing secrets in AWS Secrets Manager"

SECRET_NAME="${APP_NAME}/config"
log "Creating/updating secret in Secrets Manager..."

SECRET_VALUE="{\"JWT_SECRET\":\"${JWT_SECRET}\""
if [ "$USE_TASK_ROLE" = "false" ]; then
  SECRET_VALUE="${SECRET_VALUE},\"AWS_ACCESS_KEY_ID\":\"${AWS_ACCESS_KEY_ID_VAL}\",\"AWS_SECRET_ACCESS_KEY\":\"${AWS_SECRET_ACCESS_KEY_VAL}\""
fi
SECRET_VALUE="${SECRET_VALUE}}"

EXISTING_SECRET=$(aws secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" \
  --region "$REGION" \
  --query 'ARN' --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_SECRET" ] || [ "$EXISTING_SECRET" = "None" ]; then
  SECRET_ARN=$(aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "agentcore-chat runtime config" \
    --secret-string "$SECRET_VALUE" \
    --region "$REGION" \
    --query 'ARN' --output text)
else
  aws secretsmanager update-secret \
    --secret-id "$SECRET_NAME" \
    --secret-string "$SECRET_VALUE" \
    --region "$REGION" >/dev/null
  SECRET_ARN="$EXISTING_SECRET"
fi
success "Secrets stored: $SECRET_NAME"

# Grant the task execution role access to read the secret
aws iam put-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-name "read-agentcore-chat-secrets" \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":[\"secretsmanager:GetSecretValue\"],
      \"Resource\":\"${SECRET_ARN}\"
    }]
  }" 2>/dev/null || true

# ── TASK DEFINITION ───────────────────────────────────────────────────────────
header "Task definition"

# Build the environment variables block
ENV_VARS="[
  { \"name\": \"AGENT_ARN\",          \"value\": \"${AGENT_ARN}\" },
  { \"name\": \"AGENT_ID\",           \"value\": \"${AGENT_ID}\" },
  { \"name\": \"AGENT_ALIAS_ID\",     \"value\": \"${AGENT_ALIAS_ID}\" },
  { \"name\": \"AWS_REGION_AGENT\",   \"value\": \"${AGENT_REGION}\" },
  { \"name\": \"ALLOW_REGISTRATION\", \"value\": \"${ALLOW_REGISTRATION}\" },
  { \"name\": \"PORT\",               \"value\": \"${CONTAINER_PORT}\" },
  { \"name\": \"NODE_ENV\",           \"value\": \"production\" }
]"

# Sensitive vars come from Secrets Manager
SECRETS_BLOCK="[
  { \"name\": \"JWT_SECRET\", \"valueFrom\": \"${SECRET_ARN}:JWT_SECRET::\" }"
if [ "$USE_TASK_ROLE" = "false" ]; then
  SECRETS_BLOCK="${SECRETS_BLOCK},
  { \"name\": \"AWS_ACCESS_KEY_ID\",     \"valueFrom\": \"${SECRET_ARN}:AWS_ACCESS_KEY_ID::\" },
  { \"name\": \"AWS_SECRET_ACCESS_KEY\", \"valueFrom\": \"${SECRET_ARN}:AWS_SECRET_ACCESS_KEY::\" }"
fi
SECRETS_BLOCK="${SECRETS_BLOCK}]"

# Build task definition JSON
TASK_DEF_JSON="{
  \"family\": \"${APP_NAME}-webapp\",
  \"networkMode\": \"awsvpc\",
  \"requiresCompatibilities\": [\"FARGATE\"],
  \"cpu\": \"${CPU}\",
  \"memory\": \"${MEMORY}\",
  \"executionRoleArn\": \"${ROLE_ARN}\","

if [ -n "$TASK_ROLE_ARN" ]; then
  TASK_DEF_JSON="${TASK_DEF_JSON}
  \"taskRoleArn\": \"${TASK_ROLE_ARN}\","
fi

TASK_DEF_JSON="${TASK_DEF_JSON}
  \"volumes\": [{
    \"name\": \"${APP_NAME}-data\",
    \"efsVolumeConfiguration\": {
      \"fileSystemId\": \"${EFS_ID}\",
      \"transitEncryption\": \"ENABLED\",
      \"authorizationConfig\": {
        \"accessPointId\": \"${ACCESS_POINT_ID}\",
        \"iam\": \"DISABLED\"
      }
    }
  }],
  \"containerDefinitions\": [{
    \"name\": \"${APP_NAME}-webapp\",
    \"image\": \"${CONTAINER_IMAGE}\",
    \"essential\": true,
    \"portMappings\": [{ \"containerPort\": ${CONTAINER_PORT}, \"protocol\": \"tcp\" }],
    \"environment\": ${ENV_VARS},
    \"secrets\": ${SECRETS_BLOCK},
    \"mountPoints\": [{
      \"sourceVolume\": \"${APP_NAME}-data\",
      \"containerPath\": \"/data\",
      \"readOnly\": false
    }],
    \"healthCheck\": {
      \"command\": [\"CMD-SHELL\", \"curl -f http://localhost:${CONTAINER_PORT}/api/health || exit 1\"],
      \"interval\": 30,
      \"timeout\": 5,
      \"retries\": 3,
      \"startPeriod\": 15
    },
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\": \"${LOG_GROUP}\",
        \"awslogs-region\": \"${REGION}\",
        \"awslogs-stream-prefix\": \"ecs\"
      }
    }
  }]
}"

log "Registering task definition..."
TASK_DEF_ARN=$(echo "$TASK_DEF_JSON" | aws ecs register-task-definition \
  --region "$REGION" \
  --cli-input-json file:///dev/stdin \
  --query 'taskDefinition.taskDefinitionArn' --output text)
success "Task definition: $TASK_DEF_ARN"

# ── APPLICATION LOAD BALANCER ─────────────────────────────────────────────────
header "Application Load Balancer"

log "Creating ALB (or reusing if it exists)..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${APP_NAME}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${APP_NAME}-alb" \
    --subnets "$SUBNET_1" "$SUBNET_2" \
    --security-groups "$ALB_SG_ID" \
    --scheme internet-facing \
    --type application \
    --region "$REGION" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
fi

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text --region "$REGION")
success "ALB: $ALB_DNS"

log "Creating target group (or reusing if it exists)..."
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "${APP_NAME}-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${APP_NAME}-tg" \
    --protocol HTTP \
    --port $CONTAINER_PORT \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-path /api/health \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
fi
success "Target group: $TG_ARN"

log "Creating ALB listener..."
EXISTING_LISTENER=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[0].ListenerArn' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$EXISTING_LISTENER" ] || [ "$EXISTING_LISTENER" = "None" ]; then
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
    --region "$REGION" >/dev/null
fi
success "Listener created (port 80 → container port $CONTAINER_PORT)"

# ── ECS SERVICE ───────────────────────────────────────────────────────────────
header "ECS service"

FRONTEND_URL="http://${ALB_DNS}"

log "Creating ECS service (or updating if it exists)..."
EXISTING_SVC=$(aws ecs describe-services \
  --cluster "$APP_NAME" --services "${APP_NAME}-webapp" \
  --query 'services[?status!=`INACTIVE`].status' \
  --output text --region "$REGION" 2>/dev/null || echo "")

if [ -n "$EXISTING_SVC" ] && [ "$EXISTING_SVC" != "None" ]; then
  aws ecs update-service \
    --cluster "$APP_NAME" \
    --service "${APP_NAME}-webapp" \
    --desired-count 1 \
    --force-new-deployment \
    --region "$REGION" >/dev/null
else
  aws ecs create-service \
    --cluster "$APP_NAME" \
    --service-name "${APP_NAME}-webapp" \
    --task-definition "${APP_NAME}-webapp" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={
      subnets=[$SUBNET_1,$SUBNET_2],
      securityGroups=[$ECS_SG_ID],
      assignPublicIp=ENABLED
    }" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=${APP_NAME}-webapp,containerPort=${CONTAINER_PORT}" \
    --health-check-grace-period-seconds 30 \
    --region "$REGION" >/dev/null
fi
success "ECS service created"

# ── SAVE STATE ────────────────────────────────────────────────────────────────
cat > "$STATE_FILE" <<EOF
# agentcore-chat deployment state — generated by deploy.sh
# Used by manage.sh, update.sh, teardown.sh, and restore-state.sh — do not delete.
APP_NAME=$APP_NAME
APP_DISPLAY_NAME=$APP_DISPLAY_NAME
REGION=$REGION
ACCOUNT_ID=$ACCOUNT_ID
VPC_ID=$VPC_ID
SUBNET_1=$SUBNET_1
SUBNET_2=$SUBNET_2
ALB_SG_ID=$ALB_SG_ID
ECS_SG_ID=$ECS_SG_ID
EFS_ID=$EFS_ID
ACCESS_POINT_ID=$ACCESS_POINT_ID
ALB_ARN=$ALB_ARN
ALB_DNS=$ALB_DNS
TG_ARN=$TG_ARN
LOG_GROUP=$LOG_GROUP
TASK_DEF_ARN=$TASK_DEF_ARN
CONTAINER_IMAGE=$CONTAINER_IMAGE
SECRET_ARN=$SECRET_ARN
AGENT_ARN=$AGENT_ARN
AGENT_ID=$AGENT_ID
AGENT_ALIAS_ID=$AGENT_ALIAS_ID
AGENT_REGION=$AGENT_REGION
EOF
success "State saved to $STATE_FILE"

# ── WAIT FOR HEALTHY ──────────────────────────────────────────────────────────
header "Waiting for app to become healthy"
log "This takes 3-5 minutes while the container starts and the ALB health checks pass..."
echo ""

attempt=0
max=40
while [ $attempt -lt $max ]; do
  RUNNING=$(aws ecs describe-services \
    --cluster "$APP_NAME" \
    --services "${APP_NAME}-webapp" \
    --query 'services[0].runningCount' \
    --output text --region "$REGION" 2>/dev/null || echo "0")
  HEALTH=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' \
    --output text --region "$REGION" 2>/dev/null || echo "unknown")
  echo -ne "  Running tasks: ${RUNNING} | ALB target health: ${HEALTH}\r"
  if [ "$RUNNING" = "1" ] && [ "$HEALTH" = "healthy" ]; then
    echo ""
    break
  fi
  sleep 10
  attempt=$((attempt + 1))
done

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Deployment complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}App URL:${NC}    http://${ALB_DNS}/"
echo -e "  ${BOLD}Health:${NC}     http://${ALB_DNS}/api/health"
echo ""
echo -e "  ${YELLOW}First visit: register your admin account on the login screen.${NC}"
echo -e "  ${YELLOW}Registration will auto-lock after the first account is created.${NC}"
echo ""
echo -e "  Run ${BOLD}./manage.sh${NC} to stop, start, restart, or view logs."
echo -e "  Run ${BOLD}./teardown.sh${NC} to delete all AWS resources."
echo ""
