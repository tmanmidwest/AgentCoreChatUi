import { useState } from "react";
import { useAuth } from "../hooks/useAuth.jsx";

const APP_NAME = import.meta.env.VITE_APP_NAME || "Agent Chat";

export default function LoginPage() {
  const { login, register } = useAuth();
  const [mode, setMode] = useState("login"); // "login" | "register"
  const [form, setForm] = useState({ username: "", password: "", displayName: "" });
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }));

  const submit = async (e) => {
    e.preventDefault();
    setError("");
    setLoading(true);
    try {
      if (mode === "login") {
        await login(form.username, form.password);
      } else {
        await register(form.username, form.password, form.displayName);
      }
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={styles.root}>
      <div style={styles.card}>
        {/* Logo mark */}
        <div style={styles.logoRow}>
          <div style={styles.logoMark}>
            <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
              <circle cx="10" cy="10" r="9" stroke="#4f8ef7" strokeWidth="1.5" />
              <path d="M6 10.5l2.5 2.5L14 7.5" stroke="#4f8ef7" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </div>
          <span style={styles.appName}>{APP_NAME}</span>
        </div>

        <h1 style={styles.heading}>
          {mode === "login" ? "Sign in" : "Create account"}
        </h1>
        <p style={styles.sub}>
          {mode === "login"
            ? "Enter your credentials to continue."
            : "Set up your account to get started."}
        </p>

        <form onSubmit={submit} style={styles.form}>
          {mode === "register" && (
            <Field
              label="Display name"
              type="text"
              value={form.displayName}
              onChange={set("displayName")}
              placeholder="Your name"
              autoComplete="name"
            />
          )}
          <Field
            label="Username"
            type="text"
            value={form.username}
            onChange={set("username")}
            placeholder="you"
            autoComplete={mode === "login" ? "username" : "username"}
            required
          />
          <Field
            label="Password"
            type="password"
            value={form.password}
            onChange={set("password")}
            placeholder="••••••••"
            autoComplete={mode === "login" ? "current-password" : "new-password"}
            required
          />

          {error && <p style={styles.error}>{error}</p>}

          <button type="submit" disabled={loading} style={styles.btn}>
            {loading ? "Please wait…" : mode === "login" ? "Sign in" : "Create account"}
          </button>
        </form>

        <p style={styles.toggle}>
          {mode === "login" ? "Need an account?" : "Already have an account?"}{" "}
          <button
            type="button"
            style={styles.link}
            onClick={() => { setMode(mode === "login" ? "register" : "login"); setError(""); }}
          >
            {mode === "login" ? "Register" : "Sign in"}
          </button>
        </p>
      </div>
    </div>
  );
}

function Field({ label, ...props }) {
  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <input style={styles.input} {...props} />
    </div>
  );
}

const styles = {
  root: {
    minHeight: "100vh",
    background: "var(--bg)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    padding: "1rem",
  },
  card: {
    background: "var(--surface)",
    border: "1px solid var(--border)",
    borderRadius: "var(--radius-lg)",
    padding: "2rem",
    width: "100%",
    maxWidth: "380px",
    animation: "fade-in 0.2s ease",
  },
  logoRow: {
    display: "flex",
    alignItems: "center",
    gap: "0.5rem",
    marginBottom: "1.5rem",
  },
  logoMark: {
    width: 32,
    height: 32,
    background: "var(--accent-dim)",
    borderRadius: "var(--radius-sm)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  appName: {
    fontWeight: 600,
    color: "var(--text-primary)",
    fontSize: "0.9rem",
  },
  heading: {
    fontSize: "1.35rem",
    fontWeight: 600,
    color: "var(--text-primary)",
    marginBottom: "0.3rem",
  },
  sub: {
    color: "var(--text-secondary)",
    fontSize: "0.85rem",
    marginBottom: "1.5rem",
  },
  form: {
    display: "flex",
    flexDirection: "column",
    gap: "1rem",
  },
  field: {
    display: "flex",
    flexDirection: "column",
    gap: "0.4rem",
  },
  label: {
    fontSize: "0.82rem",
    fontWeight: 500,
    color: "var(--text-secondary)",
  },
  input: {
    background: "var(--surface-2)",
    border: "1px solid var(--border)",
    borderRadius: "var(--radius-sm)",
    color: "var(--text-primary)",
    padding: "0.6rem 0.75rem",
    fontSize: "0.9rem",
    transition: "border-color 0.15s",
  },
  error: {
    background: "rgba(240,79,85,0.1)",
    border: "1px solid rgba(240,79,85,0.3)",
    borderRadius: "var(--radius-sm)",
    color: "var(--danger)",
    fontSize: "0.83rem",
    padding: "0.5rem 0.75rem",
  },
  btn: {
    background: "var(--accent)",
    color: "#fff",
    border: "none",
    borderRadius: "var(--radius-sm)",
    padding: "0.7rem",
    fontSize: "0.9rem",
    fontWeight: 500,
    marginTop: "0.25rem",
    transition: "background 0.15s, opacity 0.15s",
  },
  toggle: {
    textAlign: "center",
    fontSize: "0.82rem",
    color: "var(--text-secondary)",
    marginTop: "1.25rem",
  },
  link: {
    background: "none",
    border: "none",
    color: "var(--accent)",
    fontSize: "inherit",
    padding: 0,
    textDecoration: "underline",
  },
};
