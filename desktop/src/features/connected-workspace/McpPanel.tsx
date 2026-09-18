import * as React from "react";
import { invoke } from "@tauri-apps/api/core";
import { Button } from "@/shared/ui/button";
import { Textarea } from "@/shared/ui/textarea";
import type { ConnectedApp } from "./model";

type Tool = { name: string; description?: string; inputSchema?: unknown };
type Reply = {
  error?: { message: string };
  result?: { tools?: Tool[]; isError?: boolean; [key: string]: unknown };
};
export function McpPanel({
  app,
  onClose,
}: {
  app: ConnectedApp;
  onClose: () => void;
}) {
  const [tools, setTools] = React.useState<Tool[]>([]);
  const [tool, setTool] = React.useState<Tool | null>(null);
  const [args, setArgs] = React.useState("{}");
  const [busy, setBusy] = React.useState(false);
  const [error, setError] = React.useState("");
  const [result, setResult] = React.useState("");
  const generation = React.useRef(0);
  React.useEffect(
    () => () => {
      generation.current++;
    },
    [],
  );
  async function send(method: string, params: unknown) {
    const token = ++generation.current;
    setBusy(true);
    setError("");
    setResult("");
    try {
      const response = await invoke<Reply>("connected_mcp_request", {
        endpoint: app.mcpUrl,
        method,
        params,
      });
      if (token !== generation.current) return;
      if (response.error) throw new Error(response.error.message);
      if (method === "tools/list") setTools(response.result?.tools || []);
      else setResult(JSON.stringify(response.result, null, 2));
      if (response.result?.isError)
        setError("The service reported a tool error; no success is assumed.");
    } catch (err) {
      if (token === generation.current) setError(String(err));
    } finally {
      if (token === generation.current) setBusy(false);
    }
  }
  function call() {
    try {
      if (!tool) return;
      const values = JSON.parse(args);
      if (!values || typeof values !== "object" || Array.isArray(values))
        throw new Error("Arguments must be a JSON object");
      if (
        !window.confirm(
          `Run ${tool.name} on ${app.mcpUrl} as YOU? Review the arguments first. A grant or write can change service data or another identity’s access.`,
        )
      )
        return;
      void send("tools/call", { name: tool.name, arguments: values });
    } catch (err) {
      setError(String(err));
    }
  }
  return (
    <section className="space-y-4 overflow-auto p-5">
      <Button variant="outline" onClick={onClose}>
        Back to apps
      </Button>
      <h3 className="font-medium">{app.name} · service tools</h3>
      <p className="break-all text-xs text-muted-foreground">{app.mcpUrl}</p>
      <p className="text-sm">
        These calls use your Buzz identity, not an agent’s key or your browser
        session. The service decides what you may do. For agent access, use its
        grant tools and name the intended agent public key; all copies holding
        that key share the grant.
      </p>
      <Button disabled={busy} onClick={() => void send("tools/list", {})}>
        Discover permitted tools
      </Button>
      {busy && (
        <p role="status" className="text-sm">
          Waiting for service…
        </p>
      )}
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      <div className="flex flex-wrap gap-2">
        {tools.map((item) => (
          <Button
            variant={tool?.name === item.name ? "default" : "outline"}
            key={item.name}
            disabled={busy}
            onClick={() => {
              setTool(item);
              setArgs("{}");
              setResult("");
            }}
          >
            {item.name}
          </Button>
        ))}
      </div>
      {tool && (
        <>
          <p className="text-sm">{tool.description}</p>
          <details>
            <summary className="text-sm">Required argument schema</summary>
            <pre className="overflow-auto rounded border p-3 text-xs">
              {JSON.stringify(tool.inputSchema, null, 2)}
            </pre>
          </details>
          <label className="block text-sm" htmlFor="connected-tool-args">
            Arguments
            <Textarea
              id="connected-tool-args"
              rows={8}
              value={args}
              onChange={(e) => setArgs(e.target.value)}
              disabled={busy}
            />
          </label>
          <Button disabled={busy} onClick={call}>
            Review and run {tool.name}
          </Button>
        </>
      )}
      {result && (
        <pre
          data-testid="connected-tool-response"
          className="whitespace-pre-wrap break-all rounded border p-3 text-xs"
        >
          {result}
        </pre>
      )}
    </section>
  );
}
