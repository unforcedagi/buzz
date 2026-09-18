export type ConnectedApp = {
  id: string;
  name: string;
  url: string;
  kind: "parachute" | "web";
  channelId: string | null;
  mcpUrl?: string;
};
export type FleetHost = {
  id: string;
  name: string;
  sshHost: string | null;
  binary: string;
  stateDir: string | null;
};
export type Workspace = {
  version: 1;
  apps: ConnectedApp[];
  hosts: FleetHost[];
};
export type Unit = {
  name: string;
  revision: string;
  pubkey: string | null;
  relay_url: string | null;
  model: string;
  system_prompt: string;
  process_running: boolean;
};
export type HostReply = {
  protocol: number;
  ok: boolean;
  error?: string;
  message?: string;
  observed_at?: number;
  units?: Unit[];
  unit?: Unit;
  configuration_saved?: boolean;
};

export function workspaceKey(pubkey: string, relay: string): string {
  return `buzz-connected.v1:${encodeURIComponent(pubkey)}:${encodeURIComponent(relay)}`;
}
export function secureAppUrl(value: string): string {
  const url = new URL(value);
  const local =
    url.protocol === "http:" &&
    ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (
    (url.protocol !== "https:" && !local) ||
    url.username ||
    url.password ||
    url.hostname.endsWith(".localhost")
  )
    throw new Error(
      "Use HTTPS or loopback HTTP, without credentials or reserved app origins",
    );
  return url.href;
}
export function parseWorkspace(value: string | null): Workspace {
  if (value === null) return { version: 1, apps: [], hosts: [] };
  const data = JSON.parse(value) as Workspace;
  if (
    data.version !== 1 ||
    !Array.isArray(data.apps) ||
    !Array.isArray(data.hosts) ||
    data.apps.length > 100 ||
    data.hosts.length > 100
  )
    throw new Error("Invalid connected workspace file");
  for (const app of data.apps) {
    if (app.mcpUrl) secureAppUrl(app.mcpUrl);
    if (
      typeof app.id !== "string" ||
      typeof app.name !== "string" ||
      !["web", "parachute"].includes(app.kind) ||
      !(app.channelId === null || typeof app.channelId === "string")
    )
      throw new Error("Invalid app entry");
    secureAppUrl(app.url);
  }
  for (const host of data.hosts) {
    if (
      typeof host.id !== "string" ||
      typeof host.name !== "string" ||
      typeof host.binary !== "string" ||
      !host.binary.startsWith("/") ||
      !(host.sshHost === null || typeof host.sshHost === "string") ||
      !(host.stateDir === null || typeof host.stateDir === "string")
    )
      throw new Error("Invalid host entry");
  }
  return data;
}
