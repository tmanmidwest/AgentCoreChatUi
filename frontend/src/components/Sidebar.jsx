import { useEffect, useState, useCallback } from "react";
import { MessageSquare, Plus, Trash2, Pencil, Check, X, LogOut, ChevronLeft } from "lucide-react";
import { api } from "../utils/api.js";
import { useAuth } from "../hooks/useAuth.jsx";

const APP_NAME = import.meta.env.VITE_APP_NAME || "Agent Chat";

export default function Sidebar({ activeId, onSelect, onNew, collapsed, onToggle }) {
  const { user, logout } = useAuth();
  const [conversations, setConversations] = useState([]);
  const [editingId, setEditingId] = useState(null);
  const [editTitle, setEditTitle] = useState("");

  const load = useCallback(async () => {
    try {
      const data = await api.history.list();
      setConversations(data.conversations);
    } catch {}
  }, []);

  useEffect(() => { load(); }, [load, activeId]);

  const handleDelete = async (e, id) => {
    e.stopPropagation();
    if (!confirm("Delete this conversation?")) return;
    await api.history.delete(id);
    setConversations((c) => c.filter((x) => x.id !== id));
    if (activeId === id) onNew();
  };

  const startEdit = (e, conv) => {
    e.stopPropagation();
    setEditingId(conv.id);
    setEditTitle(conv.title || "Untitled");
  };

  const saveEdit = async (id) => {
    if (editTitle.trim()) {
      await api.history.rename(id, editTitle.trim());
      setConversations((c) =>
        c.map((x) => (x.id === id ? { ...x, title: editTitle.trim() } : x))
      );
    }
    setEditingId(null);
  };

  if (collapsed) {
    return (
      <div style={styles.collapsed}>
        <button style={styles.collapseBtn} onClick={onToggle} title="Expand sidebar">
          <ChevronLeft size={16} style={{ transform: "rotate(180deg)" }} />
        </button>
        <button style={styles.iconBtn} onClick={onNew} title="New chat">
          <Plus size={18} />
        </button>
      </div>
    );
  }

  return (
    <div style={styles.sidebar}>
      {/* Header */}
      <div style={styles.header}>
        <div style={styles.brand}>
          <div style={styles.brandDot} />
          <span style={styles.brandName}>{APP_NAME}</span>
        </div>
        <button style={styles.collapseBtn} onClick={onToggle} title="Collapse">
          <ChevronLeft size={16} />
        </button>
      </div>

      {/* New chat */}
      <button style={styles.newBtn} onClick={onNew}>
        <Plus size={15} />
        New chat
      </button>

      {/* Conversation list */}
      <div style={styles.list}>
        {conversations.length === 0 && (
          <p style={styles.empty}>No conversations yet.</p>
        )}
        {conversations.map((c) => (
          <div
            key={c.id}
            style={{
              ...styles.item,
              ...(c.id === activeId ? styles.itemActive : {}),
            }}
            onClick={() => onSelect(c.id)}
          >
            <MessageSquare size={13} style={{ flexShrink: 0, marginTop: 1, color: "var(--text-muted)" }} />
            {editingId === c.id ? (
              <input
                style={styles.editInput}
                value={editTitle}
                autoFocus
                onChange={(e) => setEditTitle(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") saveEdit(c.id);
                  if (e.key === "Escape") setEditingId(null);
                }}
                onClick={(e) => e.stopPropagation()}
              />
            ) : (
              <span style={styles.itemTitle}>{c.title || "Untitled"}</span>
            )}
            <div style={styles.itemActions}>
              {editingId === c.id ? (
                <>
                  <button style={styles.actionBtn} onClick={(e) => { e.stopPropagation(); saveEdit(c.id); }}><Check size={12} /></button>
                  <button style={styles.actionBtn} onClick={(e) => { e.stopPropagation(); setEditingId(null); }}><X size={12} /></button>
                </>
              ) : (
                <>
                  <button style={styles.actionBtn} onClick={(e) => startEdit(e, c)} title="Rename"><Pencil size={12} /></button>
                  <button style={{ ...styles.actionBtn, ...styles.deleteBtn }} onClick={(e) => handleDelete(e, c.id)} title="Delete"><Trash2 size={12} /></button>
                </>
              )}
            </div>
          </div>
        ))}
      </div>

      {/* Footer - user */}
      <div style={styles.footer}>
        <div style={styles.avatar}>{(user?.displayName || "U")[0].toUpperCase()}</div>
        <span style={styles.footerName}>{user?.displayName || user?.username}</span>
        <button style={styles.logoutBtn} onClick={logout} title="Sign out">
          <LogOut size={14} />
        </button>
      </div>
    </div>
  );
}

const styles = {
  sidebar: {
    width: 240,
    flexShrink: 0,
    height: "100vh",
    background: "var(--surface)",
    borderRight: "1px solid var(--border)",
    display: "flex",
    flexDirection: "column",
    overflow: "hidden",
  },
  collapsed: {
    width: 52,
    flexShrink: 0,
    height: "100vh",
    background: "var(--surface)",
    borderRight: "1px solid var(--border)",
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    paddingTop: "0.75rem",
    gap: "0.5rem",
  },
  header: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "0.9rem 0.75rem 0.75rem",
    borderBottom: "1px solid var(--border)",
  },
  brand: {
    display: "flex",
    alignItems: "center",
    gap: "0.5rem",
  },
  brandDot: {
    width: 8,
    height: 8,
    borderRadius: "50%",
    background: "var(--accent)",
    boxShadow: "0 0 6px var(--accent)",
  },
  brandName: {
    fontSize: "0.82rem",
    fontWeight: 600,
    color: "var(--text-primary)",
  },
  collapseBtn: {
    background: "none",
    border: "none",
    color: "var(--text-muted)",
    padding: "4px",
    borderRadius: "var(--radius-sm)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  iconBtn: {
    background: "none",
    border: "none",
    color: "var(--text-secondary)",
    padding: "6px",
    borderRadius: "var(--radius-sm)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  newBtn: {
    display: "flex",
    alignItems: "center",
    gap: "0.5rem",
    margin: "0.75rem",
    padding: "0.5rem 0.75rem",
    background: "var(--accent-dim)",
    color: "var(--accent)",
    border: "1px solid rgba(79,142,247,0.2)",
    borderRadius: "var(--radius-sm)",
    fontSize: "0.83rem",
    fontWeight: 500,
    transition: "background 0.15s",
  },
  list: {
    flex: 1,
    overflowY: "auto",
    padding: "0.25rem 0.5rem",
  },
  empty: {
    color: "var(--text-muted)",
    fontSize: "0.8rem",
    textAlign: "center",
    padding: "1.5rem 0",
  },
  item: {
    display: "flex",
    alignItems: "center",
    gap: "0.5rem",
    padding: "0.5rem 0.5rem",
    borderRadius: "var(--radius-sm)",
    cursor: "pointer",
    transition: "background 0.1s",
    position: "relative",
  },
  itemActive: {
    background: "var(--surface-3)",
  },
  itemTitle: {
    flex: 1,
    fontSize: "0.82rem",
    color: "var(--text-secondary)",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  editInput: {
    flex: 1,
    background: "var(--surface-3)",
    border: "1px solid var(--border-mid)",
    borderRadius: "4px",
    color: "var(--text-primary)",
    fontSize: "0.82rem",
    padding: "2px 6px",
  },
  itemActions: {
    display: "flex",
    gap: "2px",
    flexShrink: 0,
    opacity: 0,
  },
  actionBtn: {
    background: "none",
    border: "none",
    color: "var(--text-muted)",
    padding: "3px",
    borderRadius: "3px",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  deleteBtn: {
    color: "var(--danger)",
  },
  footer: {
    display: "flex",
    alignItems: "center",
    gap: "0.5rem",
    padding: "0.75rem",
    borderTop: "1px solid var(--border)",
  },
  avatar: {
    width: 28,
    height: 28,
    borderRadius: "50%",
    background: "var(--accent-dim)",
    border: "1px solid rgba(79,142,247,0.3)",
    color: "var(--accent)",
    fontSize: "0.75rem",
    fontWeight: 600,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
  },
  footerName: {
    flex: 1,
    fontSize: "0.82rem",
    color: "var(--text-secondary)",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  logoutBtn: {
    background: "none",
    border: "none",
    color: "var(--text-muted)",
    padding: "4px",
    borderRadius: "var(--radius-sm)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
  },
};
