import express from "express";
import cors from "cors";
import { rateLimit } from "express-rate-limit";
import dotenv from "dotenv";
import { createRequire } from "module";
import { fileURLToPath } from "url";
import path from "path";
import { authRouter } from "./routes/auth.js";
import { chatRouter } from "./routes/chat.js";
import { historyRouter } from "./routes/history.js";
import { initDb } from "./db.js";
import { requireAuth } from "./middleware/auth.js";

dotenv.config();

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, "../../public");

const app = express();
const PORT = process.env.PORT || 3001;

// Middleware
app.use(express.json());
app.use(
  cors({
    origin: process.env.FRONTEND_URL || "*",
    credentials: true,
  })
);

// Rate limiting
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
});
app.use(limiter);

const chatLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 20,
  message: { error: "Too many messages, please slow down." },
});

// API routes — must be registered before the static file catch-all
app.use("/api/auth", authRouter);
app.use("/api/chat", requireAuth, chatLimiter, chatRouter);
app.use("/api/history", requireAuth, historyRouter);

app.get("/api/health", (req, res) => {
  res.json({ status: "ok", agentArn: process.env.AGENT_ARN ? "configured" : "missing" });
});

// Serve the built React frontend from /public
// In production the Dockerfile copies the Vite build output there.
// In local dev the frontend runs separately on :5173 so this is a no-op.
import fs from "fs";
if (fs.existsSync(PUBLIC_DIR)) {
  app.use(express.static(PUBLIC_DIR));
  // SPA fallback — send index.html for any non-API route so React Router works
  app.get("*", (req, res) => {
    res.sendFile(path.join(PUBLIC_DIR, "index.html"));
  });
}

// Init DB then start
initDb();
app.listen(PORT, () => {
  console.log(`🚀 Backend running on http://localhost:${PORT}`);
  console.log(`   Agent ARN: ${process.env.AGENT_ARN || "(not set — check .env)"}`);
  console.log(`   Serving frontend from: ${PUBLIC_DIR}`);
});
