# AgentCore Chat

A clean, self-hosted chat interface for AWS Bedrock AgentCore runtime agents. React frontend + Node.js backend, per-user chat history, simple username/password auth.

---

## Stack

| Layer | Tech |
|-------|------|
| Frontend | React 18, Vite, react-markdown |
| Backend | Node.js (ESM), Express |
| Database | SQLite via better-sqlite3 |
| Auth | JWT (8h expiry), bcrypt passwords |
| Agent | AWS Bedrock AgentCore via `@aws-sdk/client-bedrock-agent-runtime` |

---

## Quick start (local dev)

```bash
git clone <your-repo>
cd agentcore-chat

# 1. Backend env
cp backend/.env.example backend/.env
# Edit backend/.env — fill in AGENT_ARN, AWS creds, JWT_SECRET (AGENT_ENDPOINT_NAME defaults to DEFAULT)

# 2. Frontend env
cp frontend/.env.example frontend/.env
# VITE_API_URL=http://localhost:3001 is the default — leave as-is for local dev

# 3. Install and run
npm install
npm run dev
```

Open http://localhost:5173. The first registration creates an admin account; after that, registration is closed unless you set `ALLOW_REGISTRATION=true`.

---

## Configuration

### Backend `.env`

| Variable | Required | Description |
|----------|----------|-------------|
| `AGENT_ARN` | ✅ | Full ARN of your AgentCore runtime agent (`arn:aws:bedrock-agentcore:…:runtime/…`) |
| `AGENT_ENDPOINT_NAME` | – | Endpoint (qualifier) to invoke. Shown in the **Endpoints** tab of your agent. Default: `DEFAULT` |
| `AWS_REGION_AGENT` | – | Region the AgentCore runtime is in. Falls back to `AWS_REGION`, then `us-east-1` |
| `AWS_REGION` | ✅ | Default AWS region for the SDK (e.g. `us-east-1`) |
| `AWS_ACCESS_KEY_ID` | ⚠️ | For local/Vercel/Railway. Omit on ECS (use IAM role) |
| `AWS_SECRET_ACCESS_KEY` | ⚠️ | Same as above |
| `JWT_SECRET` | ✅ | Random 32+ char string. Generate: `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"` |
| `FRONTEND_URL` | ✅ | URL of your frontend (for CORS). Comma-separate multiple. |
| `PORT` | – | Default: `3001` |
| `ALLOW_REGISTRATION` | – | `"true"` to open public registration. Default: `false` |
| `DB_PATH` | – | SQLite file path. Default: `./data/chat.db` |

> **\* AgentCore note:** AgentCore runtime agents are invoked by **runtime ARN + endpoint name**, not by agent ID / alias ID (those belong to the older Bedrock *Agents* service, which this app does not use). Set `AGENT_ARN` to the full `…:runtime/…` ARN and leave `AGENT_ENDPOINT_NAME` as `DEFAULT` unless you created a named endpoint. There is no `AGENT_ID` / `AGENT_ALIAS_ID` to look up.

### Frontend `.env`

| Variable | Description |
|----------|-------------|
| `VITE_API_URL` | URL of your backend API. In production, this is your Railway/ECS URL. |
| `VITE_APP_NAME` | Display name shown in the UI. Default: `Agent Chat` |

---

## Deploying to a new agent / AWS environment

This repo is designed to be reusable across agents and environments. To point it at a different agent:

1. Set a new `AGENT_ARN` (and `AGENT_ENDPOINT_NAME` if not `DEFAULT`) in the backend `.env`
2. Update `AWS_REGION` if it's in a different region
3. Update AWS credentials to an IAM user/role that has `bedrock-agentcore:InvokeAgentRuntime` permission on the new agent
4. Restart the backend — no code changes needed

---

## Deployment options

### Option A — Railway (easiest, ~5 min)

Railway runs the Docker container and provides a managed SQLite volume.

1. Push this repo to GitHub
2. Go to https://railway.app → New Project → Deploy from GitHub repo
3. Railway auto-detects `railway.toml` and the `Dockerfile`
4. Set environment variables in the Railway dashboard (Variables tab)
5. Enable a persistent volume mounted at `/data` (for SQLite)
6. Deploy frontend separately to **Vercel** (see below) or serve the built static files from the same container

**IAM policy for Railway (access keys):**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "bedrock-agentcore:InvokeAgentRuntime",
    "Resource": [
      "arn:aws:bedrock-agentcore:us-east-1:YOUR_ACCOUNT:runtime/*",
      "arn:aws:bedrock-agentcore:us-east-1:YOUR_ACCOUNT:runtime/*/runtime-endpoint/*"
    ]
  }]
}
```

---

### Option B — Vercel (frontend) + Railway (backend)

1. **Backend on Railway** — as above, but set `FRONTEND_URL` to your Vercel URL
2. **Frontend on Vercel:**
   ```bash
   vercel
   ```
   Set these Vercel env vars:
   - `VITE_API_URL` → your Railway backend URL (e.g. `https://my-backend.railway.app`)
   - `VITE_APP_NAME` → whatever you want

---

### Option C — ECS (Fargate)

Best for company-wide scale or if you want VPC isolation.

```bash
# Build and push
docker build -t agentcore-chat .
docker tag agentcore-chat:latest <ecr-uri>:latest
docker push <ecr-uri>:latest
```

ECS task definition notes:
- Assign a task role with `bedrock-agentcore:InvokeAgentRuntime` (no access keys needed)
- Mount an EFS volume at `/data` for SQLite persistence, or swap SQLite for RDS Postgres (see below)
- Set all env vars as ECS secrets via SSM Parameter Store or Secrets Manager

---

### Option D — Docker locally or on a VM

```bash
# Copy and fill in the env file
cp backend/.env.example .env

# Run everything
docker-compose up --build
```

Frontend served by Vite dev server at :5173, backend at :3001.

---

## Swapping SQLite for Postgres (optional, for scale)

The backend uses SQLite by default — fine for teams up to ~50 concurrent users. For larger deployments:

1. Install `pg` package: `npm install pg --workspace=backend`
2. Replace `better-sqlite3` calls in `backend/src/db.js` with `pg` queries
3. Set `DATABASE_URL` instead of `DB_PATH`

The schema in `db.js` is standard SQL and works as-is on Postgres.

---

## Managing users

After first-run setup, `ALLOW_REGISTRATION=false` locks the registration screen. To add users without opening registration:

```bash
# One-shot: set ALLOW_REGISTRATION=true, register the user, set it back to false
# Or use the SQLite CLI directly:
sqlite3 data/chat.db

INSERT INTO users (id, username, password_hash, display_name)
VALUES (
  lower(hex(randomblob(16))),
  'newuser',
  -- generate hash: node -e "const b=require('bcryptjs');console.log(b.hashSync('password123',12))"
  '$2a$12$...',
  'New User'
);
```

---

## Project structure

```
agentcore-chat/
├── backend/
│   ├── src/
│   │   ├── index.js          # Express app entry
│   │   ├── db.js             # SQLite init + schema
│   │   ├── middleware/
│   │   │   └── auth.js       # JWT verification
│   │   └── routes/
│   │       ├── auth.js       # login, register, change-password
│   │       ├── chat.js       # AgentCore streaming
│   │       └── history.js    # conversation CRUD
│   ├── .env.example
│   └── package.json
├── frontend/
│   ├── src/
│   │   ├── App.jsx           # Root shell + routing
│   │   ├── index.css         # Global CSS + design tokens
│   │   ├── components/
│   │   │   ├── MessageBubble.jsx
│   │   │   └── Sidebar.jsx
│   │   ├── hooks/
│   │   │   └── useAuth.jsx   # Auth context
│   │   ├── pages/
│   │   │   ├── LoginPage.jsx
│   │   │   └── ChatPage.jsx
│   │   └── utils/
│   │       └── api.js        # API + SSE streaming client
│   ├── .env.example
│   ├── index.html
│   └── vite.config.js
├── Dockerfile                # Backend container
├── docker-compose.yml        # Full-stack local dev
├── railway.toml              # Railway deploy config
├── vercel.json               # Vercel frontend deploy
└── README.md
```

---

## Security notes

- Passwords are hashed with bcrypt (cost factor 12)
- JWTs expire after 8 hours; re-login is required
- Rate limiting: 100 req/15min global, 20 messages/min for chat
- CORS restricted to `FRONTEND_URL`
- SQLite file should not be in a web-accessible path
- In production, run behind HTTPS (Railway/Vercel handle this; for ECS, put an ALB in front)

---

## License

MIT
