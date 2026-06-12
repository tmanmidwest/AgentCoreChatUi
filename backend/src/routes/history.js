import { Router } from "express";
import { getDb } from "../db.js";

export const historyRouter = Router();

// GET /api/history/conversations
historyRouter.get("/conversations", (req, res) => {
  const db = getDb();
  const conversations = db
    .prepare(
      `SELECT id, title, created_at, updated_at,
       (SELECT COUNT(*) FROM messages WHERE conversation_id = conversations.id) as message_count
       FROM conversations WHERE user_id = ?
       ORDER BY updated_at DESC LIMIT 50`
    )
    .all(req.user.sub);
  res.json({ conversations });
});

// GET /api/history/conversations/:id
historyRouter.get("/conversations/:id", (req, res) => {
  const db = getDb();
  const conversation = db
    .prepare("SELECT * FROM conversations WHERE id = ? AND user_id = ?")
    .get(req.params.id, req.user.sub);

  if (!conversation) return res.status(404).json({ error: "Conversation not found." });

  const messages = db
    .prepare("SELECT id, role, content, created_at FROM messages WHERE conversation_id = ? ORDER BY created_at ASC")
    .all(conversation.id);

  res.json({ conversation, messages });
});

// DELETE /api/history/conversations/:id
historyRouter.delete("/conversations/:id", (req, res) => {
  const db = getDb();
  const result = db
    .prepare("DELETE FROM conversations WHERE id = ? AND user_id = ?")
    .run(req.params.id, req.user.sub);

  if (result.changes === 0) return res.status(404).json({ error: "Conversation not found." });
  res.json({ deleted: true });
});

// PATCH /api/history/conversations/:id - rename
historyRouter.patch("/conversations/:id", (req, res) => {
  const { title } = req.body;
  if (!title?.trim()) return res.status(400).json({ error: "Title is required." });

  const db = getDb();
  const result = db
    .prepare("UPDATE conversations SET title = ? WHERE id = ? AND user_id = ?")
    .run(title.trim(), req.params.id, req.user.sub);

  if (result.changes === 0) return res.status(404).json({ error: "Conversation not found." });
  res.json({ updated: true });
});
