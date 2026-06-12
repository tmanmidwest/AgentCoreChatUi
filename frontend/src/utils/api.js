const BASE = import.meta.env.VITE_API_URL || "";

function getToken() {
  return localStorage.getItem("token");
}

async function request(path, options = {}) {
  const token = getToken();
  const res = await fetch(`${BASE}${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...options.headers,
    },
  });

  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw Object.assign(new Error(body.error || `HTTP ${res.status}`), { status: res.status });
  }

  return res.json();
}

export const api = {
  auth: {
    login: (username, password) =>
      request("/api/auth/login", { method: "POST", body: JSON.stringify({ username, password }) }),
    register: (username, password, displayName) =>
      request("/api/auth/register", { method: "POST", body: JSON.stringify({ username, password, displayName }) }),
    changePassword: (currentPassword, newPassword) =>
      request("/api/auth/change-password", { method: "POST", body: JSON.stringify({ currentPassword, newPassword }) }),
  },
  history: {
    list: () => request("/api/history/conversations"),
    get: (id) => request(`/api/history/conversations/${id}`),
    delete: (id) => request(`/api/history/conversations/${id}`, { method: "DELETE" }),
    rename: (id, title) =>
      request(`/api/history/conversations/${id}`, { method: "PATCH", body: JSON.stringify({ title }) }),
  },
  health: () => request("/api/health"),
};

// Streaming chat — returns an async iterator of SSE events
export async function sendMessage(message, conversationId, { onChunk, onDone, onError } = {}) {
  const token = getToken();
  const res = await fetch(`${BASE}/api/chat/send`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({ message, conversationId }),
  });

  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.error || `HTTP ${res.status}`);
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n\n");
    buffer = lines.pop(); // keep incomplete chunk

    for (const line of lines) {
      if (!line.startsWith("data: ")) continue;
      try {
        const event = JSON.parse(line.slice(6));
        if (event.type === "chunk" && onChunk) onChunk(event.text);
        if (event.type === "done" && onDone) onDone(event);
        if (event.type === "error" && onError) onError(event.error);
      } catch {}
    }
  }
}
