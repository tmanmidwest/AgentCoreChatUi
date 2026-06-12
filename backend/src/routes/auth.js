import { Router } from "express";
import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import { v4 as uuidv4 } from "uuid";
import { getDb } from "../db.js";

export const authRouter = Router();

const TOKEN_EXPIRY = "8h";

// POST /api/auth/login
authRouter.post("/login", (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.status(400).json({ error: "Username and password are required." });
  }

  const db = getDb();
  const user = db.prepare("SELECT * FROM users WHERE username = ?").get(username.toLowerCase().trim());

  if (!user || !bcrypt.compareSync(password, user.password_hash)) {
    return res.status(401).json({ error: "Invalid username or password." });
  }

  db.prepare("UPDATE users SET last_login = datetime('now') WHERE id = ?").run(user.id);

  const token = jwt.sign(
    { sub: user.id, username: user.username, displayName: user.display_name },
    process.env.JWT_SECRET,
    { expiresIn: TOKEN_EXPIRY }
  );

  res.json({
    token,
    user: { id: user.id, username: user.username, displayName: user.display_name },
  });
});

// POST /api/auth/register
// Only works if ALLOW_REGISTRATION=true OR no users exist yet (first-run setup)
authRouter.post("/register", (req, res) => {
  const db = getDb();
  const userCount = db.prepare("SELECT COUNT(*) as count FROM users").get();
  const isFirstUser = userCount.count === 0;
  const registrationOpen = process.env.ALLOW_REGISTRATION === "true";

  if (!isFirstUser && !registrationOpen) {
    return res.status(403).json({
      error: "Registration is closed. Ask an admin to create your account.",
    });
  }

  const { username, password, displayName } = req.body;
  if (!username || !password) {
    return res.status(400).json({ error: "Username and password are required." });
  }
  if (password.length < 8) {
    return res.status(400).json({ error: "Password must be at least 8 characters." });
  }

  const existing = db.prepare("SELECT id FROM users WHERE username = ?").get(username.toLowerCase().trim());
  if (existing) {
    return res.status(409).json({ error: "Username already taken." });
  }

  const id = uuidv4();
  const hash = bcrypt.hashSync(password, 12);
  db.prepare(
    "INSERT INTO users (id, username, password_hash, display_name) VALUES (?, ?, ?, ?)"
  ).run(id, username.toLowerCase().trim(), hash, displayName || username);

  const token = jwt.sign(
    { sub: id, username: username.toLowerCase(), displayName: displayName || username },
    process.env.JWT_SECRET,
    { expiresIn: TOKEN_EXPIRY }
  );

  res.status(201).json({
    token,
    user: { id, username: username.toLowerCase(), displayName: displayName || username },
    isFirstUser,
  });
});

// POST /api/auth/change-password
authRouter.post("/change-password", (req, res) => {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) return res.status(401).json({ error: "Unauthorized." });

  let payload;
  try {
    payload = jwt.verify(header.slice(7), process.env.JWT_SECRET);
  } catch {
    return res.status(401).json({ error: "Token invalid." });
  }

  const { currentPassword, newPassword } = req.body;
  if (!currentPassword || !newPassword || newPassword.length < 8) {
    return res.status(400).json({ error: "Provide current password and a new password (min 8 chars)." });
  }

  const db = getDb();
  const user = db.prepare("SELECT * FROM users WHERE id = ?").get(payload.sub);
  if (!user || !bcrypt.compareSync(currentPassword, user.password_hash)) {
    return res.status(401).json({ error: "Current password is incorrect." });
  }

  const hash = bcrypt.hashSync(newPassword, 12);
  db.prepare("UPDATE users SET password_hash = ? WHERE id = ?").run(hash, user.id);
  res.json({ message: "Password updated." });
});
