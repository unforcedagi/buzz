import assert from "node:assert/strict";
import test from "node:test";
import {
  applyConnection,
  connectionChanges,
  ConnectionSync,
} from "./connectionSync.ts";
import { relayClient } from "../../shared/api/relayClient.ts";
const empty = { version: 1, apps: [], hosts: [] };
const app = {
  id: "notes",
  name: "Notes",
  kind: "web",
  url: "https://notes.example",
  channelId: null,
};
test("independent connection additions merge and tombstones remove only their target", () => {
  const one = applyConnection(empty, { type: "app", id: app.id, value: app });
  const two = applyConnection(one, {
    type: "app",
    id: "board",
    value: { ...app, id: "board" },
  });
  assert.equal(two.apps.length, 2);
  const removed = applyConnection(two, {
    type: "app",
    id: app.id,
    value: null,
  });
  assert.deepEqual(
    removed.apps.map((item) => item.id),
    ["board"],
  );
  assert.deepEqual(connectionChanges(two, removed), [
    { type: "app", id: app.id, value: null },
  ]);
});
test("retired sync managers never sign or publish into a new community", async () => {
  const sync = new ConnectionSync("person");
  sync.destroy();
  await assert.rejects(
    sync.publish({ type: "app", id: app.id, value: app }),
    /Community changed/,
  );
});
test("live subscription overlaps bootstrap and rejects another author's record", async () => {
  const previousWindow = globalThis.window;
  globalThis.window = {
    __TAURI_INTERNALS__: {
      invoke: async (command, args) => {
        if (command === "nip44_decrypt_from_self") return args.ciphertext;
        throw new Error(command);
      },
    },
  };
  const subscribe = relayClient.subscribeLive,
    fetch = relayClient.fetchEvents;
  const order = [],
    changes = [],
    errors = [];
  const event = {
    id: "e1",
    pubkey: "person",
    created_at: 1,
    kind: 30078,
    tags: [["d", "connected-workspace-v1:app:notes"]],
    content: JSON.stringify({ type: "app", id: app.id, value: app }),
    sig: "",
  };
  relayClient.subscribeLive = async (_filter, listener) => {
    order.push("subscribe");
    listener({ ...event, pubkey: "other" });
    return async () => {};
  };
  relayClient.fetchEvents = async () => {
    order.push("fetch");
    return [event];
  };
  const sync = new ConnectionSync("person");
  try {
    const stop = await sync.start(
      (change) => changes.push(change),
      (error) => errors.push(error),
    );
    assert.deepEqual(order, ["subscribe", "fetch"]);
    assert.equal(changes.length, 1);
    assert.equal(errors.length, 0);
    sync.destroy();
    await stop();
  } finally {
    relayClient.subscribeLive = subscribe;
    relayClient.fetchEvents = fetch;
    globalThis.window = previousWindow;
  }
});
