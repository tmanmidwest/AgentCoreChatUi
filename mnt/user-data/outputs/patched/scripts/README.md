# agentcore-chat — AWS ECS Fargate Deploy Scripts

Deploy, manage, update, and teardown the agentcore-chat app on your own AWS account.
Each person runs these scripts against their own AWS account — fully isolated instances.

The app itself lives in the sibling directory (the React + Node.js source). These
scripts build it, push it to ECR, and run it on Fargate.

---

## What you need

- **AWS account** with permissions for ECS, ECR, EFS, EC2, ELB, IAM, Secrets Manager, Bedrock
- **AWS CLI v2** — https://aws.amazon.com/cli/
- **Docker Desktop** — https://www.docker.com/products/docker-desktop/
- **Node.js** — https://nodejs.org/ (for frontend build)
- **Git** — on Mac run `xcode-select --install`

---

## Quick start (new deployment)

```bash
# Make all scripts executable (one time only)
chmod +x setup.sh deploy.sh manage.sh update.sh teardown.sh restore-state.sh

# 1. Check all prerequisites are in place
./setup.sh

# 2. Deploy — takes about 10 minutes, prints your app URL when done
./deploy.sh
```

`deploy.sh` will prompt you for:

| Prompt | Where to find it |
|--------|-----------------|
| **AWS region** | Choose from the numbered list |
| **Agent ARN** | Bedrock console → Agents → your agent → copy the ARN |
| **Agent ID** | Bedrock console → Agents → your agent → Aliases tab |
| **Agent Alias ID** | Bedrock console → Agents → your agent → Aliases tab |
| **App display name** | Whatever you want shown in the UI (e.g. "IT Helpdesk") |
| **IAM role vs access keys** | Role = recommended; keys = simpler for testing |
| **JWT secret** | Leave blank to auto-generate |
| **Open registration** | No for internal tools; yes for broader access |

First visit to the app: register your admin account on the login screen.
Registration auto-locks after the first account is created (unless you chose open).

---

## Deploying from a different agent or AWS environment

The same scripts work for any agent. Just run `./deploy.sh` from a fresh directory
and enter the new agent's ARN / ID / alias when prompted. Each deployment is fully
isolated in its own AWS account.

To switch an existing deployment to a different agent without redeploying from scratch:

```bash
./update.sh --reconfigure
```

This prompts for new agent ARN / ID / alias, updates the ECS task definition, and
force-redeploys — no image rebuild needed.

---

## Pushing an update

When changes have been merged to the main branch on GitHub:

```bash
./update.sh
```

Shows you the exact commit being deployed, asks for confirmation, rebuilds the image
and redeploys automatically.

---

## Day-to-day management

```bash
./manage.sh status     # Is it running? What's the URL?
./manage.sh stop       # Pause the app — data kept, Fargate charges stop
./manage.sh start      # Resume after stopping
./manage.sh restart    # Restart without a code change
./manage.sh logs       # Stream live logs (Ctrl+C to stop)
./manage.sh url        # Print the app URL
./manage.sh config     # Show agent ARN, app name, and other config
```

---

## Managing from a second machine

The management scripts read a local `.agentcore-chat-state` file that `deploy.sh` writes.
It holds AWS resource IDs and is not synced anywhere, so a second machine won't have it.

To manage an existing deployment from another machine:

```bash
chmod +x restore-state.sh
./restore-state.sh             # uses your default AWS region
./restore-state.sh us-west-2   # or pass the region you deployed to
```

You'll be re-prompted for the agent ARN / ID / alias (these can't be discovered from
AWS resource names). All other values are rediscovered automatically.

---

## Remove everything

```bash
./teardown.sh
```

Deletes all AWS resources — ECS, ECR, EFS, ALB, security groups, logs, and secrets.
Type `delete` to confirm. Stops all charges. **All chat history and user data is permanently deleted.**

---

## How costs work

While running (~1 task):
- **Fargate:** ~$0.02/hr (0.5 vCPU, 1GB RAM)
- **ALB:** ~$0.50/day
- **EFS:** ~$0.30/GB/month (SQLite is tiny — cents/month)
- **ECR:** ~$0.10/GB/month for stored images

When stopped (`./manage.sh stop`): Fargate charges stop. ALB still runs (~$0.50/day).
When torn down (`./teardown.sh`): all charges stop.

---

## IAM permissions required

Your AWS user needs access to: ECS, ECR, EFS, EC2, ELB, IAM, CloudWatch Logs,
Secrets Manager, and Bedrock. If using an IAM role instead of access keys, the
task role (`agentcore-chat-task-role`) is created automatically by `deploy.sh`.

The Bedrock policy on the task role looks like:
```json
{
  "Effect": "Allow",
  "Action": ["bedrock-agentcore:InvokeAgentRuntime"],
  "Resource": [
    "arn:aws:bedrock-agentcore:REGION:ACCOUNT:runtime/YOUR_AGENT",
    "arn:aws:bedrock-agentcore:REGION:ACCOUNT:runtime/YOUR_AGENT/runtime-endpoint/*"
  ]
}
```

---

## Secrets

Sensitive values (JWT secret, AWS access keys if used) are stored in AWS Secrets Manager
under `agentcore-chat/config` — never in the state file or the container image.
`teardown.sh` deletes the secret along with everything else.

---

## Adding users

Registration locks after the first account. To add users without opening registration:

```bash
# Option 1: temporarily open registration
# Set ALLOW_REGISTRATION=true in the task definition env vars, restart, register, set back.

# Option 2: connect to the EFS volume and use sqlite3 directly
# (requires an EC2 instance or ECS exec session in the same VPC)
```

---

## Script reference

| Script | Purpose |
|--------|---------|
| `setup.sh` | Check all prerequisites before deploying |
| `deploy.sh` | Full deployment from scratch (~10 min), prompts for all config |
| `update.sh` | Rebuild and redeploy from latest GitHub source |
| `update.sh --reconfigure` | Change agent ARN / IDs / app name without rebuilding |
| `manage.sh` | Stop, start, restart, logs, status, config |
| `restore-state.sh` | Rebuild state file from AWS (e.g. on a second machine) |
| `teardown.sh` | Delete all AWS resources |
