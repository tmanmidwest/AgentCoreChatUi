import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { Copy, Check } from "lucide-react";
import { useState } from "react";

export default function MessageBubble({ role, content, streaming }) {
  const isUser = role === "user";
  const [copied, setCopied] = useState(false);

  const copy = () => {
    navigator.clipboard.writeText(content);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div style={{ ...styles.row, ...(isUser ? styles.rowUser : {}) }}>
      {!isUser && <div style={styles.agentAvatar}>A</div>}
      <div style={{ ...styles.bubble, ...(isUser ? styles.bubbleUser : styles.bubbleAgent) }}>
        {isUser ? (
          <p style={{ margin: 0, whiteSpace: "pre-wrap", fontSize: "0.9rem" }}>{content}</p>
        ) : (
          <div className="md-body">
            <ReactMarkdown remarkPlugins={[remarkGfm]}>{content}</ReactMarkdown>
            {streaming && <span style={styles.cursor} />}
          </div>
        )}
        {!isUser && !streaming && content && (
          <button style={styles.copyBtn} onClick={copy} title="Copy response">
            {copied ? <Check size={12} /> : <Copy size={12} />}
          </button>
        )}
      </div>
      {isUser && <div style={styles.userAvatar} />}
    </div>
  );
}

const styles = {
  row: {
    display: "flex",
    gap: "0.75rem",
    alignItems: "flex-start",
    padding: "0.5rem 0",
    animation: "fade-in 0.18s ease",
  },
  rowUser: {
    flexDirection: "row-reverse",
  },
  agentAvatar: {
    width: 28,
    height: 28,
    borderRadius: "50%",
    background: "var(--accent-dim)",
    border: "1px solid rgba(79,142,247,0.3)",
    color: "var(--accent)",
    fontSize: "0.7rem",
    fontWeight: 700,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    marginTop: 2,
  },
  userAvatar: {
    width: 28,
    height: 28,
    flexShrink: 0,
  },
  bubble: {
    maxWidth: "80%",
    borderRadius: "var(--radius-md)",
    padding: "0.65rem 0.9rem",
    fontSize: "0.9rem",
    lineHeight: 1.65,
    position: "relative",
  },
  bubbleAgent: {
    background: "var(--surface-2)",
    border: "1px solid var(--border)",
    color: "var(--text-primary)",
  },
  bubbleUser: {
    background: "var(--user-bubble)",
    border: "1px solid var(--user-border)",
    color: "var(--text-primary)",
  },
  cursor: {
    display: "inline-block",
    width: 2,
    height: "1em",
    background: "var(--accent)",
    marginLeft: 2,
    verticalAlign: "middle",
    animation: "pulse-dot 0.8s ease-in-out infinite",
  },
  copyBtn: {
    position: "absolute",
    top: "0.4rem",
    right: "0.4rem",
    background: "none",
    border: "none",
    color: "var(--text-muted)",
    padding: "3px",
    borderRadius: "4px",
    display: "flex",
    alignItems: "center",
    opacity: 0,
    transition: "opacity 0.15s",
  },
};
