import assert from "node:assert/strict";
import test from "node:test";
import { fleetGroups } from "./fleetGroups.ts";
test("same identity groups across hosts while operations retain explicit copies", () => {
  const hosts = [
    { id: "one", name: "Uni" },
    { id: "two", name: "Spark" },
  ];
  const groups = fleetGroups(hosts, {
    one: { units: [{ name: "techne", pubkey: "key" }] },
    two: { units: [{ name: "unforced", pubkey: "key" }] },
  });
  assert.equal(groups.length, 1);
  assert.deepEqual(
    groups[0].copies.map(({ host, unit }) => [host.id, unit.name]),
    [
      ["one", "techne"],
      ["two", "unforced"],
    ],
  );
});
test("units without an identity never collapse by display name", () => {
  const hosts = [{ id: "one" }, { id: "two" }];
  assert.equal(
    fleetGroups(hosts, {
      one: { units: [{ name: "agent", pubkey: null }] },
      two: { units: [{ name: "agent", pubkey: null }] },
    }).length,
    2,
  );
});
