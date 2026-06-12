import { Router } from "express";
import { v4 as uuidv4 } from "uuid";
import {
  BedrockAgentCoreRuntimeClient,
  InvokeAgentRuntimeCommand,
} from "@aws-sdk/client-bedrock-agentcore-runtime";
import { getDb } from "../db.js";

export const chatRouter = Router();

// AgentCore runtime client — region comes from the ARN, not the deployment region
function getAgentClient() {
  const region = process.env.AWS_REGION_AGENT || process.env.AWS_REGION || "us-east-1";
  return new BedrockAgentCoreRuntimeClient({ region });
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

  // Derive the endpoint name from the ARN or use AGENT_ENDPOINT_NAME override.
  // ARN format: arn:aws:bedrock-agentcore:REGION:ACCOUNT:runtime/RUNTIME_ID
  // The endpoint name defaults to "DEFAULT" — override via AGENT_ENDPOINT_NAME if needed.
  const endpointName = process.env.AGENT_ENDPOINT_NAME || "DEFAULT";

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

  // Set up SSE stream to the browser
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.flushHeaders();

  const client = getAgentClient();
  let fullResponse = "";

  try {
    const command = new InvokeAgentRuntimeCommand({
      agentRuntimeArn: agentArn,
      agentRuntimeEndpointName: endpointName,
      sessionId: conversation.agent_session_id,
      // AgentCore runtime expects the payload as a JSON string
      payload: JSON.stringify({ inputText: message.trim() }),
    });

    const response = await client.send(command);

    // Stream chunks to the browser as they arrive
    for await (const event of response.body) {
      if (event.chunk?.bytes) {
        const raw = new TextDecoder().decode(event.chunk.bytes);
        // The runtime may return JSON-wrapped chunks or plain text — handle both
        let text = raw;
        try {
          const parsed = JSON.parse(raw);
          text = parsed.outputText ?? parsed.text ?? parsed.content ?? raw;
        } catch {
          // plain text chunk — use as-is
        }
        fullResponse += text;
        res.write(`data: ${JSON.stringify({ type: "chunk", text })}\n\n`);
      }
    }

    // Persist the full assistant reply
    const assistantMsgId = uuidv4();
    db.prepare(
      "INSERT INTO messages (id, conversation_id, role, content) VALUES (?, ?, 'assistant', ?)"
    ).run(assistantMsgId, conversation.id, fullResponse);

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
    console.error("AgentCore runtime error:", err);
    let errorMsg = "The agent returned an error. Please try again.";
    if (err.name === "ThrottlingException") {
      errorMsg = "The agent is busy. Please wait a moment and try again.";
    } else if (err.name === "ValidationException") {
      errorMsg = "Invalid request to the agent. Check your AGENT_ARN and endpoint name.";
    } else if (err.name === "AccessDeniedException") {
      errorMsg = "Access denied. Check that your AWS credentials have bedrock-agentcore:InvokeAgentRuntime permission.";
    }
    res.write(`data: ${JSON.stringify({ type: "error", error: errorMsg })}\n\n`);
  } finally {
    res.end();
  }
});
