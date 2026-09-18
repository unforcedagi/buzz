import type { FleetHost, HostReply, Unit } from "./model";
export function fleetGroups(
  hosts: FleetHost[],
  inventory: Record<string, HostReply>,
) {
  const groups = new Map<
    string,
    { identity: string | null; copies: { host: FleetHost; unit: Unit }[] }
  >();
  for (const host of hosts)
    for (const unit of inventory[host.id]?.units || []) {
      const key = unit.pubkey || `${host.id}:${unit.name}`;
      const group = groups.get(key) || { identity: unit.pubkey, copies: [] };
      group.copies.push({ host, unit });
      groups.set(key, group);
    }
  return [...groups.entries()].map(([key, group]) => ({ key, ...group }));
}
