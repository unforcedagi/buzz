import * as React from "react";
import { toast } from "sonner";
import { invoke } from "@tauri-apps/api/core";
import { Button } from "@/shared/ui/button";
import { Input } from "@/shared/ui/input";
import { FleetPanel } from "./FleetPanel";
import { McpPanel } from "./McpPanel";
import {
  applyConnection,
  connectionChanges,
  ConnectionSync,
} from "./connectionSync";
import {
  parseWorkspace,
  secureAppUrl,
  workspaceKey,
  type ConnectedApp,
  type Workspace,
} from "./model";

type Props = {
  pubkey: string;
  relay: string;
  channelId: string | null;
  onDockWidth: (width: number) => void;
};

export function ConnectedWorkspace({
  pubkey,
  relay,
  channelId,
  onDockWidth,
}: Props) {
  const [open, setOpen] = React.useState(false);
  const [tab, setTab] = React.useState<"apps" | "fleet">("apps");
  const [workspace, setWorkspace] = React.useState<Workspace>({
    version: 1,
    apps: [],
    hosts: [],
  });
  const [error, setError] = React.useState("");
  const [active, setActive] = React.useState<ConnectedApp | null>(null);
  const [toolApp, setToolApp] = React.useState<ConnectedApp | null>(null);
  const [mcpUrl, setMcpUrl] = React.useState("");
  const [expanded, setExpanded] = React.useState(false);
  const [name, setName] = React.useState("Parachute");
  const [url, setUrl] = React.useState("");
  const [kind, setKind] = React.useState<"parachute" | "web">("parachute");
  const [busy, setBusy] = React.useState(false);
  const [notice, setNotice] = React.useState("");
  const surface = React.useRef<HTMLDivElement>(null);
  const panelRef = React.useRef<HTMLElement>(null);
  React.useLayoutEffect(() => {
    const panel = panelRef.current;
    if (!open || expanded || !panel) {
      onDockWidth(0);
      return;
    }
    const update = () => onDockWidth(panel.getBoundingClientRect().width);
    update();
    const observer = new ResizeObserver(update);
    observer.observe(panel);
    return () => {
      observer.disconnect();
      onDockWidth(0);
    };
  }, [open, expanded, onDockWidth]);
  const sessionRef = React.useRef<string | null>(null);
  const syncRef = React.useRef<ConnectionSync | null>(null);
  const savingRef = React.useRef(false);
  const workspaceRef = React.useRef(workspace);
  const [syncAttempt, setSyncAttempt] = React.useState(0);
  const [syncReady, setSyncReady] = React.useState(false);
  const key = workspaceKey(pubkey, relay);
  const acceptWorkspace = React.useCallback(
    (next: Workspace) => {
      workspaceRef.current = next;
      setWorkspace(next);
      try {
        localStorage.setItem(key, JSON.stringify(next));
      } catch (err) {
        setError(`Connection received but local cache failed: ${String(err)}`);
      }
    },
    [key],
  );
  React.useEffect(() => {
    try {
      const cached = parseWorkspace(localStorage.getItem(key));
      workspaceRef.current = cached;
      setWorkspace(cached);
    } catch (err) {
      setError(String(err));
    }
  }, [key]);
  // biome-ignore lint/correctness/useExhaustiveDependencies: retry intentionally restarts the subscription.
  React.useEffect(() => {
    setSyncReady(false);
    const sync = new ConnectionSync(pubkey);
    syncRef.current = sync;
    let retired = false;
    let unsubscribe: (() => Promise<void>) | undefined;
    void sync
      .start(
        (change) => {
          if (retired) return;
          acceptWorkspace(applyConnection(workspaceRef.current, change));
        },
        (err) => {
          if (!retired) setError(`Connection sync: ${String(err)}`);
        },
      )
      .then((stop) => {
        if (retired) void stop();
        else {
          unsubscribe = stop;
          setSyncReady(true);
        }
      })
      .catch((err) => {
        if (!retired) setError(`Connection sync unavailable: ${String(err)}`);
      });
    return () => {
      retired = true;
      sync.destroy();
      syncRef.current = null;
      if (unsubscribe) void unsubscribe();
    };
  }, [acceptWorkspace, pubkey, syncAttempt]);
  async function save(next: Workspace) {
    if (savingRef.current) {
      setError("A connection change is still being saved");
      return false;
    }
    savingRef.current = true;
    const sync = syncRef.current;
    try {
      if (!syncReady || !sync)
        throw new Error("Wait for connection sync, then retry");
      parseWorkspace(JSON.stringify(next));
      const changes = connectionChanges(workspace, next);
      if (changes.length !== 1)
        throw new Error("Change one connection at a time");
      const accepted = await sync.publish(changes[0]);
      if (syncRef.current !== sync) return false;
      if (!accepted)
        throw new Error(
          "A newer connection edit arrived from another device. Review it before retrying.",
        );
      setError("");
      acceptWorkspace(applyConnection(workspaceRef.current, changes[0]));
      return true;
    } catch (err) {
      setError(`Could not save connections: ${String(err)}`);
      return false;
    } finally {
      savingRef.current = false;
    }
  }
  React.useEffect(() => {
    if (!active || !open || tab !== "apps" || !surface.current) return;
    let cancelled = false;
    let ready = false;
    const session = crypto.randomUUID();
    sessionRef.current = session;
    setBusy(false);
    const element = surface.current;
    const bounds = () => {
      const r = element.getBoundingClientRect();
      return { x: r.x, y: r.y, width: r.width, height: r.height };
    };
    void invoke("connected_app_open", {
      session,
      url: active.url,
      bounds: bounds(),
    })
      .then(() => {
        ready = true;
        if (cancelled)
          void invoke("connected_app_close", { session }).catch((err) =>
            toast.error(
              `Could not close retired app surface: ${String(err)}. Close the window to end the app session.`,
            ),
          );
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      });
    const observer = new ResizeObserver(() => {
      if (ready && !cancelled)
        void invoke("connected_app_bounds", {
          session,
          bounds: bounds(),
        }).catch((err) => {
          if (!cancelled) setError(String(err));
        });
    });
    observer.observe(element);
    return () => {
      cancelled = true;
      observer.disconnect();
      sessionRef.current = null;
      void invoke("connected_app_close", { session }).catch((err) =>
        toast.error(
          `Could not close app surface: ${String(err)}. Close the window to end the app session.`,
        ),
      );
    };
  }, [active, open, tab]);
  React.useEffect(() => {
    function onEscape(event: KeyboardEvent) {
      if (event.key === "Escape") {
        setOpen(false);
        setActive(null);
      }
    }
    window.addEventListener("keydown", onEscape);
    return () => window.removeEventListener("keydown", onEscape);
  }, []);
  async function signIn() {
    if (!active) return;
    setBusy(true);
    setError("");
    const session = sessionRef.current;
    try {
      const result = await invoke<string>("connected_parachute_sign_in", {
        session,
        origin: new URL(active.url).origin,
        returnTo: active.url,
      });
      if (sessionRef.current === session) setNotice(result);
    } catch (err) {
      if (sessionRef.current === session) setError(String(err));
    } finally {
      if (sessionRef.current === session) setBusy(false);
    }
  }
  async function copyReference() {
    try {
      const location = await invoke<string>("connected_app_location", {
        session: sessionRef.current,
      });
      await navigator.clipboard.writeText(location);
      setNotice(
        "Resource link copied. Paste into the conversation; access permissions are unchanged.",
      );
    } catch (err) {
      setError(String(err));
    }
  }
  return (
    <>
      <Button
        variant="ghost"
        size="sm"
        data-testid="connected-workspace-toggle"
        onClick={() => {
          setOpen(!open);
          if (open) setActive(null);
        }}
      >
        Apps & fleet
      </Button>
      {open && (
        <aside
          ref={panelRef}
          aria-label="Connected workspace"
          className={`fixed bottom-0 right-0 top-14 z-40 flex flex-col border-l bg-background shadow-xl ${expanded ? "w-[calc(100vw-5rem)]" : "w-[min(44rem,55vw)]"}`}
        >
          <header className="flex shrink-0 items-center gap-2 border-b p-3">
            <Button
              variant={tab === "apps" ? "default" : "ghost"}
              onClick={() => setTab("apps")}
            >
              Connected apps
            </Button>
            <Button
              variant={tab === "fleet" ? "default" : "ghost"}
              onClick={() => {
                setActive(null);
                setTab("fleet");
              }}
            >
              Fleet
            </Button>
            <div className="flex-1" />
            <Button variant="ghost" onClick={() => setExpanded(!expanded)}>
              {expanded ? "Dock" : "Expand"}
            </Button>
            <Button
              variant="ghost"
              aria-label="Close connected workspace"
              onClick={() => {
                setOpen(false);
                setActive(null);
              }}
            >
              Close
            </Button>
          </header>
          {!syncReady && (
            <Button
              variant="ghost"
              onClick={() => setSyncAttempt((n) => n + 1)}
            >
              Retry connection sync
            </Button>
          )}
          {error && (
            <p
              role="alert"
              className="shrink-0 border-b p-3 text-sm text-destructive"
            >
              {error}
            </p>
          )}
          {notice && (
            <p role="status" className="shrink-0 border-b p-3 text-xs">
              {notice}
            </p>
          )}
          {tab === "fleet" ? (
            <div className="overflow-auto p-5">
              <FleetPanel
                hosts={workspace.hosts}
                onHosts={(hosts) => save({ ...workspace, hosts })}
              />
            </div>
          ) : toolApp ? (
            <McpPanel
              key={toolApp.id}
              app={toolApp}
              onClose={() => setToolApp(null)}
            />
          ) : active ? (
            <>
              <div className="flex shrink-0 flex-wrap items-center gap-2 border-b p-3">
                <Button variant="outline" onClick={() => setActive(null)}>
                  All apps
                </Button>
                <span className="text-sm font-medium">{active.name}</span>
                <span className="text-xs text-muted-foreground">
                  {new URL(active.url).host}
                </span>
                <div className="flex-1" />
                {active.kind === "parachute" && (
                  <Button
                    disabled={busy}
                    variant="outline"
                    onClick={() => void signIn()}
                  >
                    Sign in with my Buzz key
                  </Button>
                )}
                <Button variant="outline" onClick={() => void copyReference()}>
                  Copy resource link
                </Button>
              </div>
              <div ref={surface} className="min-h-0 flex-1">
                <p className="p-5 text-sm text-muted-foreground">
                  Opening the app’s own interface…
                </p>
              </div>
            </>
          ) : (
            <div className="space-y-5 overflow-auto p-5">
              <p className="text-sm text-muted-foreground">
                Apps supply their own web experience. Opening a shortcut does
                not grant channel members or agents access. Parachute manages
                its accounts and agent grants inside its own interface.
              </p>
              {workspace.apps
                .filter(
                  (app) =>
                    app.channelId === null || app.channelId === channelId,
                )
                .map((app) => (
                  <div
                    key={app.id}
                    className="flex items-center gap-3 rounded-lg border p-4"
                  >
                    <div className="min-w-0 flex-1">
                      <h3 className="font-medium">{app.name}</h3>
                      <p className="break-all text-xs text-muted-foreground">
                        {app.url}
                      </p>
                    </div>
                    <Button
                      onClick={() => {
                        setError("");
                        setNotice("");
                        setActive(app);
                      }}
                    >
                      Open
                    </Button>
                    {app.mcpUrl && (
                      <Button
                        variant="outline"
                        onClick={() => {
                          setActive(null);
                          setToolApp(app);
                        }}
                      >
                        Tools & access
                      </Button>
                    )}
                    <Button
                      variant="ghost"
                      onClick={() =>
                        save({
                          ...workspace,
                          apps: workspace.apps.filter(
                            (item) => item.id !== app.id,
                          ),
                        })
                      }
                    >
                      Remove
                    </Button>
                  </div>
                ))}
              <form
                className="grid gap-3 rounded-lg border p-4"
                onSubmit={(event) => {
                  event.preventDefault();
                  try {
                    const app: ConnectedApp = {
                      mcpUrl: mcpUrl
                        ? secureAppUrl(mcpUrl)
                        : kind === "parachute"
                          ? new URL("/account/mcp", secureAppUrl(url)).href
                          : undefined,
                      id: crypto.randomUUID(),
                      name,
                      url: secureAppUrl(url),
                      kind,
                      channelId,
                    };
                    save({ ...workspace, apps: [...workspace.apps, app] });
                  } catch (err) {
                    setError(String(err));
                  }
                }}
              >
                <h3 className="font-medium">
                  Connect an app to this conversation
                </h3>
                <label className="text-sm" htmlFor="connected-app-name">
                  Name
                  <Input
                    id="connected-app-name"
                    required
                    maxLength={100}
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                  />
                </label>
                <label className="text-sm" htmlFor="connected-app-url">
                  HTTPS app or project URL
                  <Input
                    id="connected-app-url"
                    required
                    type="url"
                    value={url}
                    onChange={(e) => setUrl(e.target.value)}
                    placeholder="https://your-parachute.example"
                  />
                </label>
                <label className="text-sm">
                  Integration
                  <select
                    className="mt-1 block w-full rounded border bg-background p-2"
                    value={kind}
                    onChange={(e) =>
                      setKind(e.target.value as "parachute" | "web")
                    }
                  >
                    <option value="parachute">
                      Parachute · optional Buzz-key sign-in
                    </option>
                    <option value="web">Web app · app-managed sign-in</option>
                  </select>
                </label>
                <p className="text-xs text-muted-foreground">
                  Remote apps cannot invoke fleet controls or access your
                  private key. Sessions are discarded when you close the app.
                  External-origin navigation is blocked.
                </p>
                <label className="text-sm" htmlFor="connected-app-mcp">
                  Nostr-authenticated MCP endpoint · optional
                  <Input
                    id="connected-app-mcp"
                    value={mcpUrl}
                    onChange={(e) => setMcpUrl(e.target.value)}
                    placeholder="Parachute defaults to /account/mcp"
                  />
                </label>
                <Button>Add shortcut</Button>
              </form>
              <p className="text-xs text-muted-foreground">
                Connections sync encrypted to your Buzz identity in this
                community. Another device can discover them, but still needs its
                own authorized network/SSH access. Host settings are always read
                from the host.
              </p>
            </div>
          )}
        </aside>
      )}
    </>
  );
}
