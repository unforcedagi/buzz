import assert from "node:assert/strict";
import test from "node:test";
import { parseWorkspace, secureAppUrl, workspaceKey } from "./model.ts";
test("app URLs reject credential and native-protocol exposure", () => {
  for (const url of [
    "http://hub.example",
    "file:///tmp/note",
    "https://key:secret@hub.example",
    "javascript:alert(1)",
  ])
    assert.throws(() => secureAppUrl(url));
  assert.equal(
    secureAppUrl("https://hub.example/notes?id=abc"),
    "https://hub.example/notes?id=abc",
  );
});
test("connection buckets separate identities and case-sensitive community paths", () => {
  assert.notEqual(
    workspaceKey("a", "wss://relay/A"),
    workspaceKey("a", "wss://relay/a"),
  );
  assert.notEqual(
    workspaceKey("a", "wss://relay"),
    workspaceKey("b", "wss://relay"),
  );
});
test("malformed saved connections fail explicitly instead of being silently reset", () => {
  assert.deepEqual(parseWorkspace(null), { version: 1, apps: [], hosts: [] });
  assert.throws(() => parseWorkspace("broken"));
  assert.throws(() =>
    parseWorkspace(JSON.stringify({ version: 2, apps: [], hosts: [] })),
  );
  assert.throws(() =>
    parseWorkspace(
      JSON.stringify({
        version: 1,
        apps: [
          {
            id: "a",
            name: "Bad",
            url: "file:///tmp",
            kind: "web",
            channelId: null,
          },
        ],
        hosts: [],
      }),
    ),
  );
});
