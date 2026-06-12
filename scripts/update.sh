#!/bin/bash
# =============================================================================
# update.sh — Rebuild and redeploy agentcore-chat from latest GitHub source
# =============================================================================
# Run this any time you have merged changes to the main branch on GitHub.
# It will:
#   1. Pull the latest code from GitHub
#   2. Build a fresh Docker image (linux/amd64 for Fargate compatibility)
#   3. Push it to your ECR repository
#   4. Force ECS to redeploy using the new image
#   5. Wait and confirm the app is healthy
#
# Optionally update agent configuration without a full redeploy:
#   ./update.sh --reconfigure    (prompts for new agent ARN / IDs / app name)
#
# Usage: ./update.sh
# =============================================================================

set -euo pipefail

GITHUB_REPO="https://github.com/tmanmidwest/AgentCoreChatUi.git"   # ← keep in sync with deploy.sh

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

# ── AWS SESSION VALIDATION ────────────────────────────────────────────────────
header "Validating AWS session"

CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session and try again."

SESSION_ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
SESSION_USER=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'].split('/')[-1])")
success "Logged in as: $SESSION_USER (Account: $SESSION_ACCOUNT)"

[ -f "$STATE_FILE" ] || error "No state file found ($STATE_FILE). Deploy the app first with ./deploy.sh"
# shellcheck source=/dev/null
source "$STATE_FILE"

# ── PRE-FLIGHT ────────────────────────────────────────────────────────────────
header "Pre-flight checks"

command -v docker >/dev/null 2>&1 || error "Docker not found. Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
docker info >/dev/null 2>&1      || error "Docker is not running. Start Docker Desktop and try again."
command -v git >/dev/null 2>&1   || error "Git not found. Install from https://git-scm.com/"
success "Docker and Git are ready"

SVC_STATUS=$(aws ecs describe-services \
  --cluster "$APP_NAME" \
  --services "${APP_NAME}-webapp" \
  --query 'services[0].status' \
  --output text --region "$REGION" 2>/dev/null || echo "")
[ "$SVC_STATUS" = "ACTIVE" ] || error "ECS service is not running. Deploy the app first with ./deploy.sh"
success "ECS service is active"

ECR_IMAGE="${SESSION_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${APP_NAME}-webapp:latest"

# ── OPTIONAL RECONFIGURE ──────────────────────────────────────────────────────
RECONFIGURE=false
if [ "${1:-}" = "--reconfigure" ]; then
  RECONFIGURE=true
fi

if [ "$RECONFIGURE" = "true" ]; then
  header "Reconfiguring agent + app settings"

  echo ""
  echo -e "  ${BOLD}Update agent configuration${NC}"
  echo -e "  Leave blank to keep the current value shown in brackets."
  echo ""

  read -rp "  Agent ARN [${AGENT_ARN}]: " NEW_AGENT_ARN
  NEW_AGENT_ARN="${NEW_AGENT_ARN:-$AGENT_ARN}"

  read -rp "  Endpoint name [${AGENT_ENDPOINT_NAME:-DEFAULT}]: " NEW_AGENT_ENDPOINT_NAME
  NEW_AGENT_ENDPOINT_NAME="${NEW_AGENT_ENDPOINT_NAME:-${AGENT_ENDPOINT_NAME:-DEFAULT}}"

  ARN_REGION=$(echo "$NEW_AGENT_ARN" | awk -F: '{print $4}')
  read -rp "  Agent region [${AGENT_REGION:-$ARN_REGION}]: " NEW_AGENT_REGION
  NEW_AGENT_REGION="${NEW_AGENT_REGION:-${AGENT_REGION:-$ARN_REGION}}"

  read -rp "  App display name [${APP_DISPLAY_NAME:-Agent Chat}]: " NEW_APP_DISPLAY_NAME
  NEW_APP_DISPLAY_NAME="${NEW_APP_DISPLAY_NAME:-${APP_DISPLAY_NAME:-Agent Chat}}"

  # Update state variables
  AGENT_ARN="$NEW_AGENT_ARN"
  AGENT_ENDPOINT_NAME="$NEW_AGENT_ENDPOINT_NAME"
  AGENT_REGION="$NEW_AGENT_REGION"
  APP_DISPLAY_NAME="$NEW_APP_DISPLAY_NAME"

  # Update task definition with new env vars
  header "Registering updated task definition"

  ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole \
    --query 'Role.Arn' --output text 2>/dev/null || error "ecsTaskExecutionRole not found")

  TASK_ROLE_ARN=""
  TASK_ROLE_NAME="${APP_NAME}-task-role"
  TASK_ROLE_ARN=$(aws iam get-role --role-name "$TASK_ROLE_NAME" \
    --query 'Role.Arn' --output text 2>/dev/null || echo "")

  # Update bedrock permission on task role if agent ARN changed
  if [ -n "$TASK_ROLE_ARN" ]; then
    log "Updating task role policy for new agent ARN..."
    aws iam put-role-policy \
      --role-name "$TASK_ROLE_NAME" \
      --policy-name "bedrock-invoke-agent" \
      --policy-document "{
        \"Version\":\"2012-10-17\",
        \"Statement\":[{
          \"Effect\":\"Allow\",
          \"Action\":[\"bedrock-agentcore:InvokeAgentRuntime\"],
          \"Resource\":[\"${AGENT_ARN}\",\"${AGENT_ARN}/runtime-endpoint/*\"]
        }]
      }" 2>/dev/null || warn "Could not update task role policy — check IAM permissions"
    success "Task role policy updated"
  fi

  CONTAINER_PORT=3001

  # Write task definition to a temp file via python3 — avoids shell JSON quoting issues
  TASK_DEF_FILE=$(mktemp /tmp/taskdef-XXXXXX.json)

  python3 - <<PYEOF > "$TASK_DEF_FILE"
import json

task_role_arn = """${TASK_ROLE_ARN}""".strip()

definition = {
    "family": "${APP_NAME}-webapp",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "512",
    "memory": "1024",
    "executionRoleArn": "${ROLE_ARN}",
    "volumes": [{
        "name": "${APP_NAME}-data",
        "efsVolumeConfiguration": {
            "fileSystemId": "${EFS_ID}",
            "transitEncryption": "ENABLED",
            "authorizationConfig": {
                "accessPointId": "${ACCESS_POINT_ID}",
                "iam": "DISABLED"
            }
        }
    }],
    "containerDefinitions": [{
        "name": "${APP_NAME}-webapp",
        "image": "${CONTAINER_IMAGE}",
        "essential": True,
        "portMappings": [{"containerPort": ${CONTAINER_PORT}, "protocol": "tcp"}],
        "environment": [
            {"name": "AGENT_ARN",            "value": "${AGENT_ARN}"},
            {"name": "AGENT_ENDPOINT_NAME",  "value": "${AGENT_ENDPOINT_NAME}"},
            {"name": "AWS_REGION_AGENT",     "value": "${AGENT_REGION}"},
            {"name": "ALLOW_REGISTRATION",   "value": "false"},
            {"name": "PORT",                 "value": "${CONTAINER_PORT}"},
            {"name": "NODE_ENV",             "value": "production"}
        ],
        "secrets": [{"name": "JWT_SECRET", "valueFrom": "${SECRET_ARN}:JWT_SECRET::"}],
        "mountPoints": [{
            "sourceVolume": "${APP_NAME}-data",
            "containerPath": "/data",
            "readOnly": False
        }],
        "healthCheck": {
            "command": ["CMD-SHELL", "curl -f http://localhost:${CONTAINER_PORT}/api/health || exit 1"],
            "interval": 30,
            "timeout": 5,
            "retries": 3,
            "startPeriod": 15
        },
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "${LOG_GROUP}",
                "awslogs-region": "${REGION}",
                "awslogs-stream-prefix": "ecs"
            }
        }
    }]
}

if task_role_arn:
    definition["taskRoleArn"] = task_role_arn

print(json.dumps(definition, indent=2))
PYEOF

  TASK_DEF_ARN=$(aws ecs register-task-definition \
    --region "$REGION" \
    --cli-input-json "file://${TASK_DEF_FILE}" \
    --query 'taskDefinition.taskDefinitionArn' --output text)
  rm -f "$TASK_DEF_FILE"
  success "Task definition updated: $TASK_DEF_ARN"

  # Update state file with new values
  cat > "$STATE_FILE" <<EOF
# agentcore-chat deployment state — updated by update.sh --reconfigure
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
AGENT_ENDPOINT_NAME=$AGENT_ENDPOINT_NAME
AGENT_REGION=$AGENT_REGION
EOF
  success "State file updated"

  log "Forcing new ECS deployment with updated configuration..."
  aws ecs update-service \
    --cluster "$APP_NAME" \
    --service "${APP_NAME}-webapp" \
    --task-definition "${APP_NAME}-webapp" \
    --force-new-deployment \
    --region "$REGION" >/dev/null

  # Jump straight to health wait
  echo ""
  log "Waiting for updated configuration to deploy..."
else
  # ── PULL LATEST CODE ────────────────────────────────────────────────────────
  header "Pulling latest code from GitHub"

  BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "$BUILD_DIR"' EXIT

  log "Cloning main branch..."
  git clone $GITHUB_REPO "$BUILD_DIR" \
    --branch main \
    --depth 1 \
    --quiet

  COMMIT_SHA=$(git -C "$BUILD_DIR" rev-parse --short HEAD)
  COMMIT_MSG=$(git -C "$BUILD_DIR" log -1 --pretty=format:"%s")
  COMMIT_DATE=$(git -C "$BUILD_DIR" log -1 --pretty=format:"%cd" --date=format:"%Y-%m-%d %H:%M")
  success "Latest commit: ${COMMIT_SHA} — ${COMMIT_MSG} (${COMMIT_DATE})"

  echo ""
  echo -e "  ${BOLD}Deploying commit ${COMMIT_SHA} to AWS. Continue?${NC}"
  read -rp "  [Y/n] " confirm
  confirm="${confirm:-Y}"
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted. Nothing was changed."; exit 0; }

  # ── BUILD IMAGE ─────────────────────────────────────────────────────────────
  header "Building Docker image"

  log "Logging Docker into ECR..."
  aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin \
    "${SESSION_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null
  success "Docker logged into ECR"

  # Inject frontend env
  cat > "$BUILD_DIR/frontend/.env" <<ENVEOF
VITE_APP_NAME=${APP_DISPLAY_NAME:-Agent Chat}
VITE_API_URL=
ENVEOF

  log "Building image for linux/amd64 (3-5 minutes on first build, faster after)..."
  docker buildx build \
    --no-cache \
    --platform linux/amd64 \
    --push \
    -t "$ECR_IMAGE" \
    "$BUILD_DIR"

  ECR_IMAGE_SHA="${SESSION_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${APP_NAME}-webapp:${COMMIT_SHA}"
  docker buildx build \
    --no-cache \
    --platform linux/amd64 \
    --push \
    -t "$ECR_IMAGE_SHA" \
    "$BUILD_DIR" --quiet

  rm -rf "$BUILD_DIR"
  trap - EXIT
  success "Image built and pushed: $ECR_IMAGE"
  success "Also tagged as: ${APP_NAME}-webapp:${COMMIT_SHA}"

  # ── REDEPLOY ECS ─────────────────────────────────────────────────────────────
  header "Redeploying to ECS"

  log "Forcing new ECS deployment with updated image..."
  aws ecs update-service \
    --cluster "$APP_NAME" \
    --service "${APP_NAME}-webapp" \
    --force-new-deployment \
    --region "$REGION" >/dev/null
  success "ECS deployment triggered"
fi

# ── WAIT FOR HEALTHY ──────────────────────────────────────────────────────────
header "Waiting for new version to become healthy"
log "ECS will start the new container and drain the old one (2-4 minutes)..."
echo ""

attempt=0
while [ $attempt -lt 40 ]; do
  RUNNING=$(aws ecs describe-services \
    --cluster "$APP_NAME" \
    --services "${APP_NAME}-webapp" \
    --query 'services[0].runningCount' \
    --output text --region "$REGION" 2>/dev/null || echo "0")
  HEALTH=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' \
    --output text --region "$REGION" 2>/dev/null || echo "unknown")
  echo -ne "  Running tasks: ${RUNNING} | ALB health: ${HEALTH}\r"
  if [ "$RUNNING" = "1" ] && [ "$HEALTH" = "healthy" ]; then
    echo ""
    break
  fi
  sleep 10
  attempt=$((attempt + 1))
done
echo ""

if [ $attempt -eq 40 ]; then
  warn "Timed out waiting for healthy status."
  warn "Check ./manage.sh status and ./manage.sh logs for details."
  exit 1
fi

echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
if [ "$RECONFIGURE" = "true" ]; then
  echo -e "${BOLD}${GREEN}  Reconfiguration complete!${NC}"
else
  echo -e "${BOLD}${GREEN}  Update complete!${NC}"
fi
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
if [ "$RECONFIGURE" = "false" ]; then
  echo -e "  ${BOLD}Deployed commit:${NC}  ${COMMIT_SHA} — ${COMMIT_MSG}"
fi
echo -e "  ${BOLD}App URL:${NC}          http://${ALB_DNS}/"
echo ""
echo -e "  Run ${BOLD}./manage.sh logs${NC} to see the new container's output."
echo ""
