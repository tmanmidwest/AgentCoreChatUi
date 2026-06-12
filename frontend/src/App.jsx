import { useState } from "react";
import { AuthProvider, useAuth } from "./hooks/useAuth.jsx";
import LoginPage from "./pages/LoginPage.jsx";
import ChatPage from "./pages/ChatPage.jsx";
import Sidebar from "./components/Sidebar.jsx";

function Shell() {
  const { user, loading } = useAuth();
  const [activeConvId, setActiveConvId] = useState(null);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);

  if (loading) {
    return (
      <div style={{ height: "100vh", display: "flex", alignItems: "center", justifyContent: "center" }}>
        <div style={{ width: 24, height: 24, border: "2px solid var(--border)", borderTopColor: "var(--accent)", borderRadius: "50%", animation: "spin 0.8s linear infinite" }} />
      </div>
    );
  }

  if (!user) return <LoginPage />;

  return (
    <div style={{ display: "flex", height: "100vh", overflow: "hidden" }}>
      <Sidebar
        activeId={activeConvId}
        onSelect={setActiveConvId}
        onNew={() => setActiveConvId(null)}
        collapsed={sidebarCollapsed}
        onToggle={() => setSidebarCollapsed((v) => !v)}
      />
      <ChatPage
        key={activeConvId ?? "new"}
        conversationId={activeConvId}
        onConversationCreated={(id) => setActiveConvId(id)}
      />
    </div>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <Shell />
    </AuthProvider>
  );
}
