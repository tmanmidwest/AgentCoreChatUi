import { Router } from "express";
import { v4 as uuidv4 } from "uuid";
import {
  BedrockAgentRuntimeClient,
  InvokeAgentCommand,
} from "@aws-sdk/client-bedrock-agent-runtime";
import { getDb } from "../db.js";

export const chatRouter = Router();

function getAgentClient() {
  return new BedrockAgentRuntimeClient({
    region: process.env.AWS_REGION || "us-east-1",
    // Credentials come from environment variables or instance profile:
    // AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
    // or IAM role if running on ECS/EC2
  });
}

// POST /api/chat/send
chatRouter.post("/send", async (req, res) => {
  const { message, conversationId } = req.body;
  if (!message?.trim()) {
    return res.status(400).json({ error: "Message cannot be empty." });
  }

  const agentArn = process.env.AGENT_ARN;
  if (!agentArn) {
    return res.status(500).json({ error: "AGENT_ARN is not configured on the server." });
  }

  const db = getDb();
  const userId = req.user.sub;

  // Get or create conversation
  let conversation;
  if (conversationId) {
    conversation = db
      .prepare("SELECT * FROM conversations WHERE id = ? AND user_id = ?")
      .get(conversationId, userId);
    if (!conversation) {
      return res.status(404).json({ error: "Conversation not found." });
    }
  } else {
    const id = uuidv4();
    const agentSessionId = uuidv4();
    // Use first ~50 chars of message as title
    const title = message.trim().slice(0, 60) + (message.length > 60 ? "…" : "");
    db.prepare(
      "INSERT INTO conversations (id, user_id, title, agent_session_id) VALUES (?, ?, ?, ?)"
    ).run(id, userId, title, agentSessionId);
    conversation = db.prepare("SELECT * FROM conversations WHERE id = ?").get(id);
  }

  // Save user message
  const userMsgId = uuidv4();
  db.prepare(
    "INSERT INTO messages (id, conversation_id, role, content) VALUES (?, ?, 'user', ?)"
  ).run(userMsgId, conversation.id, message.trim());

  // Parse ARN to extract agentId and aliasId
  // ARN format: arn:aws:bedrock-agentcore:REGION:ACCOUNT:runtime/AGENT_ID-ALIAS_ID
  // or standard: arn:aws:bedrock:REGION:ACCOUNT:agent-alias/AGENT_ID/ALIAS_ID
  let agentId, agentAliasId;

  // Support both AgentCore runtime ARN and standard Bedrock agent alias ARN
  const agentCoreMatch = agentArn.match(/runtime\/([^-]+)-(.+)$/);
  const standardMatch = agentArn.match(/agent-alias\/([^/]+)\/(.+)$/);

  if (agentCoreMatch) {
    // AgentCore style: extract from the runtime ARN using env overrides if needed
    agentId = process.env.AGENT_ID;
    agentAliasId = process.env.AGENT_ALIAS_ID;
    if (!agentId || !agentAliasId) {
      return res.status(500).json({
        error:
          "For AgentCore runtime ARNs, set AGENT_ID and AGENT_ALIAS_ID in your .env (see README).",
      });
    }
  } else if (standardMatch) {
    agentId = standardMatch[1];
    agentAliasId = standardMatch[2];
  } else {
    // Fall back to explicit env vars
    agentId = process.env.AGENT_ID;
    agentAliasId = process.env.AGENT_ALIAS_ID;
    if (!agentId || !agentAliasId) {
      return res.status(500).json({
        error: "Could not parse agent ID from ARN. Set AGENT_ID and AGENT_ALIAS_ID in .env.",
      });
    }
  }

  // Stream response to client
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.flushHeaders();

  const client = getAgentClient();
  let fullResponse = "";

  try {
    const command = new InvokeAgentCommand({
      agentId,
      agentAliasId,
      sessionId: conversation.agent_session_id,
      inputText: message.trim(),
    });

    const response = await client.send(command);

    // Stream chunks to client
    for await (const event of response.completion) {
      if (event.chunk?.bytes) {
        const text = new TextDecoder().decode(event.chunk.bytes);
        fullResponse += text;
        res.write(`data: ${JSON.stringify({ type: "chunk", text })}\n\n`);
      }
    }

    // Save assistant message
    const assistantMsgId = uuidv4();
    db.prepare(
      "INSERT INTO messages (id, conversation_id, role, content) VALUES (?, ?, 'assistant', ?)"
    ).run(assistantMsgId, conversation.id, fullResponse);

    // Update conversation timestamp
    db.prepare("UPDATE conversations SET updated_at = datetime('now') WHERE id = ?").run(
      conversation.id
    );

    res.write(
      `data: ${JSON.stringify({
        type: "done",
        conversationId: conversation.id,
        messageId: assistantMsgId,
      })}\n\n`
    );
  } catch (err) {
    console.error("AgentCore error:", err);
    const errorMsg =
      err.name === "ThrottlingException"
        ? "The agent is busy. Please wait a moment and try again."
        : "The agent returned an error. Please try again.";
    res.write(`data: ${JSON.stringify({ type: "error", error: errorMsg })}\n\n`);
  } finally {
    res.end();
  }
});
