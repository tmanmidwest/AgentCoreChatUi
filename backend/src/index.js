import express from "express";
import cors from "cors";
import { rateLimit } from "express-rate-limit";
import dotenv from "dotenv";
import { authRouter } from "./routes/auth.js";
import { chatRouter } from "./routes/chat.js";
import { historyRouter } from "./routes/history.js";
import { initDb } from "./db.js";
import { requireAuth } from "./middleware/auth.js";

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3001;

// Middleware
app.use(express.json());
app.use(
  cors({
    origin: process.env.FRONTEND_URL || "http://localhost:5173",
    credentials: true,
  })
);

// Rate limiting
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
});
app.use(limiter);

const chatLimiter = rateLimit({
  windowMs: 60 * 1000, // 1 minute
  max: 20,
  message: { error: "Too many messages, please slow down." },
});

// Routes
app.use("/api/auth", authRouter);
app.use("/api/chat", requireAuth, chatLimiter, chatRouter);
app.use("/api/history", requireAuth, historyRouter);

app.get("/api/health", (req, res) => {
  res.json({ status: "ok", agentArn: process.env.AGENT_ARN ? "configured" : "missing" });
});

// Init DB then start
initDb();
app.listen(PORT, () => {
  console.log(`🚀 Backend running on http://localhost:${PORT}`);
  console.log(`   Agent ARN: ${process.env.AGENT_ARN || "(not set — check .env)"}`);
});
