import { useState, useEffect, useRef, useCallback } from "react";
import { Send, Loader } from "lucide-react";
import MessageBubble from "../components/MessageBubble.jsx";
import { api, sendMessage } from "../utils/api.js";

const WELCOME = {
  id: "__welcome__",
  role: "assistant",
  content: "Hello! I'm your support agent. Ask me anything — I'm here to help.",
};

export default function ChatPage({ conversationId, onConversationCreated }) {
  const [messages, setMessages] = useState([WELCOME]);
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  const [streamingId, setStreamingId] = useState(null);
  const [currentConvId, setCurrentConvId] = useState(conversationId);
  const bottomRef = useRef(null);
  const textareaRef = useRef(null);

  // Load conversation history
  useEffect(() => {
    setCurrentConvId(conversationId);
    if (!conversationId) {
      setMessages([WELCOME]);
      return;
    }
    api.history.get(conversationId).then((data) => {
      setMessages(data.messages.length ? data.messages : [WELCOME]);
    }).catch(() => setMessages([WELCOME]));
  }, [conversationId]);

  // Auto-scroll
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const submit = useCallback(async () => {
    const text = input.trim();
    if (!text || sending) return;

    const userMsgId = `tmp-${Date.now()}`;
    const streamMsgId = `stream-${Date.now()}`;

    setInput("");
    setSending(true);
    setMessages((m) => [
      ...m.filter((x) => x.id !== "__welcome__"),
      { id: userMsgId, role: "user", content: text },
      { id: streamMsgId, role: "assistant", content: "", streaming: true },
    ]);
    setStreamingId(streamMsgId);

    try {
      let fullText = "";
      await sendMessage(text, currentConvId, {
        onChunk: (chunk) => {
          fullText += chunk;
          setMessages((m) =>
            m.map((msg) =>
              msg.id === streamMsgId ? { ...msg, content: fullText } : msg
            )
          );
        },
        onDone: ({ conversationId: newId }) => {
          if (!currentConvId && newId) {
            setCurrentConvId(newId);
            onConversationCreated?.(newId);
          }
          setMessages((m) =>
            m.map((msg) =>
              msg.id === streamMsgId ? { ...msg, streaming: false, id: `done-${Date.now()}` } : msg
            )
          );
        },
        onError: (err) => {
          setMessages((m) =>
            m.map((msg) =>
              msg.id === streamMsgId
                ? { ...msg, content: `⚠️ ${err}`, streaming: false }
                : msg
            )
          );
        },
      });
    } catch (err) {
      setMessages((m) =>
        m.map((msg) =>
          msg.id === streamMsgId
            ? { ...msg, content: `⚠️ ${err.message}`, streaming: false }
            : msg
        )
      );
    } finally {
      setSending(false);
      setStreamingId(null);
      textareaRef.current?.focus();
    }
  }, [input, sending, currentConvId, onConversationCreated]);

  const onKeyDown = (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submit();
    }
  };

  return (
    <div style={styles.page}>
      {/* Messages */}
      <div style={styles.messages}>
        <div style={styles.inner}>
          {messages.map((msg) => (
            <MessageBubble
              key={msg.id}
              role={msg.role}
              content={msg.content}
              streaming={msg.streaming}
            />
          ))}
          {sending && !streamingId && (
            <div style={styles.thinking}>
              <div style={styles.dot} />
              <div style={{ ...styles.dot, animationDelay: "0.15s" }} />
              <div style={{ ...styles.dot, animationDelay: "0.3s" }} />
            </div>
          )}
          <div ref={bottomRef} />
        </div>
      </div>

      {/* Input bar */}
      <div style={styles.inputBar}>
        <div style={styles.inputWrap}>
          <textarea
            ref={textareaRef}
            style={styles.textarea}
            placeholder="Ask a question… (Shift+Enter for newline)"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={onKeyDown}
            rows={1}
            disabled={sending}
          />
          <button
            style={{
              ...styles.sendBtn,
              ...((!input.trim() || sending) ? styles.sendBtnDisabled : {}),
            }}
            onClick={submit}
            disabled={!input.trim() || sending}
            title="Send"
          >
            {sending ? (
              <Loader size={16} style={{ animation: "spin 1s linear infinite" }} />
            ) : (
              <Send size={16} />
            )}
          </button>
        </div>
        <p style={styles.hint}>This agent may make mistakes. Verify important information.</p>
      </div>
    </div>
  );
}

const styles = {
  page: {
    flex: 1,
    display: "flex",
    flexDirection: "column",
    height: "100vh",
    overflow: "hidden",
  },
  messages: {
    flex: 1,
    overflowY: "auto",
    padding: "1.5rem 1rem 0.5rem",
  },
  inner: {
    maxWidth: 720,
    margin: "0 auto",
    paddingBottom: "0.5rem",
  },
  thinking: {
    display: "flex",
    gap: "5px",
    padding: "0.75rem 0.9rem",
    marginLeft: 44,
    background: "var(--surface-2)",
    border: "1px solid var(--border)",
    borderRadius: "var(--radius-md)",
    width: "fit-content",
    animation: "fade-in 0.18s ease",
  },
  dot: {
    width: 7,
    height: 7,
    borderRadius: "50%",
    background: "var(--text-muted)",
    animation: "pulse-dot 0.9s ease-in-out infinite",
  },
  inputBar: {
    padding: "0.75rem 1rem 0.6rem",
    borderTop: "1px solid var(--border)",
    background: "var(--surface)",
  },
  inputWrap: {
    maxWidth: 720,
    margin: "0 auto",
    display: "flex",
    gap: "0.5rem",
    alignItems: "flex-end",
  },
  textarea: {
    flex: 1,
    background: "var(--surface-2)",
    border: "1px solid var(--border-mid)",
    borderRadius: "var(--radius-md)",
    color: "var(--text-primary)",
    padding: "0.65rem 0.9rem",
    fontSize: "0.9rem",
    resize: "none",
    lineHeight: 1.6,
    maxHeight: 180,
    overflowY: "auto",
    transition: "border-color 0.15s",
  },
  sendBtn: {
    width: 40,
    height: 40,
    borderRadius: "var(--radius-md)",
    background: "var(--accent)",
    color: "#fff",
    border: "none",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    transition: "background 0.15s, opacity 0.15s",
  },
  sendBtnDisabled: {
    opacity: 0.4,
    cursor: "not-allowed",
  },
  hint: {
    maxWidth: 720,
    margin: "0.4rem auto 0",
    fontSize: "0.72rem",
    color: "var(--text-muted)",
    textAlign: "center",
  },
};
