import { relayClient } from "@/shared/api/relayClient";
import {
  nip44DecryptFromSelf,
  nip44EncryptToSelf,
  signRelayEvent,
} from "@/shared/api/tauri";
import type { RelayEvent } from "@/shared/api/types";
import { KIND_CONNECTED_WORKSPACE } from "@/shared/constants/kinds";
import {
  parseWorkspace,
  type ConnectedApp,
  type FleetHost,
  type Workspace,
} from "./model";

const MARKER = "connected-workspace-v1";
type Change = {
  type: "app" | "host";
  id: string;
  value: ConnectedApp | FleetHost | null;
};
export function connectionChanges(
  before: Workspace,
  after: Workspace,
): Change[] {
  const changes: Change[] = [];
  for (const type of ["app", "host"] as const) {
    const left = type === "app" ? before.apps : before.hosts;
    const right = type === "app" ? after.apps : after.hosts;
    for (const item of left)
      if (!right.some((next) => next.id === item.id))
        changes.push({ type, id: item.id, value: null });
    for (const item of right)
      if (!left.some((old) => JSON.stringify(old) === JSON.stringify(item)))
        changes.push({ type, id: item.id, value: item });
  }
  return changes;
}
export function applyConnection(
  workspace: Workspace,
  change: Change,
): Workspace {
  const next =
    change.type === "app"
      ? {
          ...workspace,
          apps: [
            ...workspace.apps.filter((app) => app.id !== change.id),
            ...(change.value ? [change.value as ConnectedApp] : []),
          ],
        }
      : {
          ...workspace,
          hosts: [
            ...workspace.hosts.filter((host) => host.id !== change.id),
            ...(change.value ? [change.value as FleetHost] : []),
          ],
        };
  return parseWorkspace(JSON.stringify(next));
}

/** One encrypted NIP-78 record per connection; independent additions cannot overwrite each other. */
export class ConnectionSync {
  private retired = false;
  private heads = new Map<string, RelayEvent>();
  private pubkey: string;
  constructor(pubkey: string) {
    this.pubkey = pubkey;
  }
  destroy() {
    this.retired = true;
  }
  private async decode(event: RelayEvent): Promise<Change | null> {
    if (this.retired || event.pubkey !== this.pubkey) return null;
    const change = JSON.parse(
      await nip44DecryptFromSelf(event.content),
    ) as Change;
    if (this.retired) return null;
    if (
      !["app", "host"].includes(change.type) ||
      typeof change.id !== "string" ||
      change.id.length > 100 ||
      (change.value !== null && change.value?.id !== change.id)
    )
      throw new Error("Invalid connection record");
    const key = `${MARKER}:${change.type}:${change.id}`;
    if (!event.tags.some((tag) => tag[0] === "d" && tag[1] === key))
      throw new Error("Connection record scope mismatch");
    const head = this.heads.get(key);
    if (
      head &&
      (head.created_at > event.created_at ||
        (head.created_at === event.created_at && head.id <= event.id))
    )
      return null;
    // Validate payload before advancing the head.
    applyConnection({ version: 1, apps: [], hosts: [] }, change);
    this.heads.set(key, event);
    return change;
  }
  async start(
    onChange: (change: Change) => void,
    onError: (error: unknown) => void,
  ): Promise<() => Promise<void>> {
    const filter = {
      kinds: [KIND_CONNECTED_WORKSPACE],
      authors: [this.pubkey],
      "#t": [MARKER],
    };
    const accept = async (event: RelayEvent) => {
      try {
        const change = await this.decode(event);
        if (change && !this.retired) onChange(change);
      } catch (err) {
        if (!this.retired) onError(err);
      }
    };
    const unsubscribe = await relayClient.subscribeLive(
      { ...filter, limit: 0 },
      (event) => {
        void accept(event);
      },
    );
    try {
      const events = await relayClient.fetchEvents({ ...filter, limit: 1000 });
      if (events.length >= 1000)
        throw new Error(
          "Connection history exceeds the current sync limit; inventory may be incomplete",
        );
      for (const event of events) await accept(event);
    } catch (err) {
      onError(err);
    }
    return unsubscribe;
  }
  async publish(change: Change): Promise<boolean> {
    if (this.retired) throw new Error("Community changed");
    const key = `${MARKER}:${change.type}:${change.id}`;
    const content = await nip44EncryptToSelf(JSON.stringify(change));
    if (this.retired) throw new Error("Community changed");
    const event = await signRelayEvent({
      kind: KIND_CONNECTED_WORKSPACE,
      content,
      createdAt: Math.max(
        Math.floor(Date.now() / 1000),
        (this.heads.get(key)?.created_at || 0) + 1,
      ),
      tags: [
        ["d", key],
        ["t", MARKER],
      ],
    });
    if (this.retired || event.pubkey !== this.pubkey)
      throw new Error("Identity or community changed");
    await relayClient.publishEvent(
      event,
      "Connection sync timed out; refresh before retrying",
      "Connection sync failed",
    );
    if (this.retired) throw new Error("Community changed");
    const head = this.heads.get(key);
    if (
      head &&
      (head.created_at > event.created_at ||
        (head.created_at === event.created_at && head.id < event.id))
    )
      return false;
    this.heads.set(key, event);
    return true;
  }
}
