import * as React from "react";
import { invoke } from "@tauri-apps/api/core";
import { Button } from "@/shared/ui/button";
import { Input } from "@/shared/ui/input";
import { Textarea } from "@/shared/ui/textarea";
import type { FleetHost, HostReply, Unit } from "./model";
import { fleetGroups } from "./fleetGroups";

export function FleetPanel({
  hosts,
  onHosts,
}: {
  hosts: FleetHost[];
  onHosts: (hosts: FleetHost[]) => Promise<boolean>;
}) {
  const [selected, setSelected] = React.useState<string | null>(null);
  const [inventory, setInventory] = React.useState<Record<string, HostReply>>(
    {},
  );
  const [busy, setBusy] = React.useState(false);
  const [error, setError] = React.useState("");
  const [message, setMessage] = React.useState("");
  const [editing, setEditing] = React.useState<Unit | null>(null);
  const [model, setModel] = React.useState("");
  const [prompt, setPrompt] = React.useState("");
  const [name, setName] = React.useState("");
  const [ssh, setSsh] = React.useState("");
  const [binary, setBinary] = React.useState("");
  const [stateDir, setStateDir] = React.useState("");
  const generation = React.useRef(0);
  React.useEffect(
    () => () => {
      generation.current++;
    },
    [],
  );
  const host = hosts.find((item) => item.id === selected);
  const response = host ? inventory[host.id] : undefined;
  const groups = fleetGroups(hosts, inventory);
  async function refreshAll() {
    const token = ++generation.current;
    setBusy(true);
    setError("");
    setEditing(null);
    const pending = [...hosts];
    const failures: string[] = [];
    async function worker() {
      while (pending.length && token === generation.current) {
        const target = pending.shift();
        if (!target) break;
        try {
          const result = await request(target, { op: "inventory" });
          if (token !== generation.current) return;
          if (!result.ok) throw new Error(result.error || "Inventory failed");
          setInventory((current) => ({ ...current, [target.id]: result }));
        } catch (err) {
          failures.push(`${target.name}: ${String(err)}`);
        }
      }
    }
    await Promise.all([worker(), worker(), worker()]);
    if (token === generation.current) {
      setBusy(false);
      setError(failures.join("; "));
    }
  }

  async function request(target: FleetHost, payload: unknown) {
    return invoke<HostReply>("fleet_request", {
      host: {
        sshHost: target.sshHost,
        binary: target.binary,
        stateDir: target.stateDir,
      },
      request: payload,
    });
  }
  async function inspect(target: FleetHost, add = false) {
    const token = ++generation.current;
    setBusy(true);
    setError("");
    setMessage("");
    setEditing(null);
    try {
      const result = await request(target, { op: "inventory" });
      if (generation.current !== token) return;
      if (!result.ok) throw new Error(result.error || "Inventory failed");
      setInventory((current) => ({ ...current, [target.id]: result }));
      if (add && !(await onHosts([...hosts, target]))) return;
      if (generation.current !== token) return;
      setSelected(target.id);
    } catch (err) {
      if (generation.current === token) setError(String(err));
    } finally {
      if (generation.current === token) setBusy(false);
    }
  }
  async function change(type: "save" | "start" | "restart" | "stop") {
    if (!host || !editing) return;
    if (
      type !== "save" &&
      !window.confirm(
        `${type.toUpperCase()} ${editing.name} on ${host.name}? This can interrupt active work.${type === "stop" ? " This stops the current service; its startup policy may start it again after reboot." : ""}`,
      )
    )
      return;
    const token = ++generation.current;
    setBusy(true);
    setError("");
    setMessage("");
    try {
      const action =
        type === "save" ? { type, model, system_prompt: prompt } : { type };
      const result = await request(host, {
        op: "change",
        name: editing.name,
        expected_revision: editing.revision,
        expires_at: Math.floor(Date.now() / 1000) + 60,
        action,
      });
      if (generation.current !== token) return;
      if (result.unit) {
        setEditing(result.unit);
        setInventory((current) => ({
          ...current,
          [host.id]: {
            ...current[host.id],
            units: current[host.id]?.units?.map((unit) =>
              unit.name === result.unit?.name ? result.unit : unit,
            ),
          },
        }));
      }
      if (!result.ok)
        throw new Error(
          `${result.error || "Operation failed"}${result.configuration_saved ? " Settings were saved. Refresh before retrying." : ""}`,
        );
      setMessage(result.message || "Host replied");
    } catch (err) {
      if (generation.current === token) setError(String(err));
    } finally {
      if (generation.current === token) setBusy(false);
    }
  }
  return (
    <div className="space-y-5">
      {hosts.length > 1 && (
        <section className="space-y-3">
          <Button
            variant="outline"
            disabled={busy}
            onClick={() => void refreshAll()}
          >
            Refresh all hosts
          </Button>
          <p className="text-xs text-muted-foreground">
            Agents across inspected hosts · grouped by public identity. Select
            one copy to manage it.
          </p>
          {groups.map((group) => (
            <div key={group.key} className="rounded-lg border p-3">
              <h3 className="text-sm font-medium">
                {group.copies[0].unit.name} · {group.copies.length}{" "}
                {group.copies.length === 1 ? "copy" : "copies"}
              </h3>
              <div className="mt-2 flex flex-wrap gap-2">
                {group.copies.map(({ host: target, unit }) => (
                  <Button
                    key={`${target.id}:${unit.name}`}
                    size="sm"
                    variant="outline"
                    disabled={busy}
                    onClick={() => {
                      setSelected(target.id);
                      setEditing(unit);
                      setModel(unit.model);
                      setPrompt(unit.system_prompt);
                    }}
                  >
                    {target.name} · {unit.name}
                  </Button>
                ))}
              </div>
            </div>
          ))}
        </section>
      )}
      <p className="text-sm text-muted-foreground">
        Connect to the machine that owns the saved configuration. Access uses
        your local or SSH operating-system account—not channel membership.
        Process state is not agent health.
      </p>
      <div className="flex flex-wrap gap-2">
        {hosts.map((item) => (
          <Button
            key={item.id}
            disabled={busy}
            variant={item.id === selected ? "default" : "outline"}
            onClick={() => void inspect(item)}
          >
            {item.name}
          </Button>
        ))}
      </div>
      <details className="rounded-lg border p-3">
        <summary className="cursor-pointer text-sm font-medium">
          Connect a host
        </summary>
        <form
          className="mt-3 grid gap-3"
          onSubmit={(event) => {
            event.preventDefault();
            void inspect(
              {
                id: crypto.randomUUID(),
                name,
                sshHost: ssh || null,
                binary,
                stateDir: stateDir || null,
              },
              true,
            );
          }}
        >
          <label className="text-sm" htmlFor="fleet-host-name">
            Host name
            <Input
              id="fleet-host-name"
              required
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Uni"
            />
          </label>
          <label className="text-sm" htmlFor="fleet-host-ssh">
            SSH alias or user@host · blank for this computer
            <Input
              id="fleet-host-ssh"
              value={ssh}
              onChange={(e) => setSsh(e.target.value)}
              placeholder="uni"
            />
          </label>
          <label className="text-sm" htmlFor="fleet-host-binary">
            Absolute buzz-host path on that machine
            <Input
              id="fleet-host-binary"
              required
              value={binary}
              onChange={(e) => setBinary(e.target.value)}
              placeholder="/Users/you/.local/bin/buzz-host"
            />
          </label>
          <label className="text-sm" htmlFor="fleet-host-state">
            State directory · optional
            <Input
              id="fleet-host-state"
              value={stateDir}
              onChange={(e) => setStateDir(e.target.value)}
            />
          </label>
          <p className="text-xs text-muted-foreground">
            Existing SSH keys and a verified known-host entry are required.
            Inspecting does not deploy or restart agents.
          </p>
          <Button disabled={busy}>Inspect and connect</Button>
        </form>
      </details>
      {busy && (
        <p role="status" className="text-sm">
          Waiting for host…
        </p>
      )}
      {error && (
        <p
          role="alert"
          className="rounded border border-destructive p-3 text-sm text-destructive"
        >
          {error} Last-known inventory below may be stale.
        </p>
      )}
      {message && (
        <p role="status" className="rounded border p-3 text-sm">
          {message}
        </p>
      )}
      {host && (
        <section className="space-y-3">
          <div className="flex items-center justify-between">
            <h3 className="font-medium">{host.name}</h3>
            <Button
              variant="outline"
              disabled={busy}
              onClick={() => void inspect(host)}
            >
              Refresh
            </Button>
          </div>
          {response?.observed_at && (
            <p className="text-xs text-muted-foreground">
              Inventory observed{" "}
              {new Date(response.observed_at * 1000).toLocaleString()}
            </p>
          )}
          {response?.units?.length === 0 && (
            <p className="text-sm">
              No installed units in this host state directory.
            </p>
          )}
          {response?.units?.map((unit) => (
            <button
              type="button"
              key={unit.name}
              disabled={busy}
              className="block w-full rounded-lg border p-3 text-left hover:bg-muted"
              onClick={() => {
                setEditing(unit);
                setModel(unit.model);
                setPrompt(unit.system_prompt);
                setMessage("");
              }}
            >
              <span className="block font-medium">{unit.name}</span>
              <span className="block text-xs text-muted-foreground">
                {unit.relay_url || "No relay recorded"} ·{" "}
                {unit.process_running
                  ? "Process running"
                  : "Process not observed running"}
              </span>
              <span className="block text-sm">
                Saved model: {unit.model || "Runtime default"}
              </span>
            </button>
          ))}
          <Button
            variant="ghost"
            disabled={busy}
            onClick={async () => {
              if (!(await onHosts(hosts.filter((item) => item.id !== host.id))))
                return;
              setSelected(null);
              setEditing(null);
            }}
          >
            Forget connection · keep agents running
          </Button>
        </section>
      )}
      {editing && host && (
        <section className="space-y-3 rounded-lg border p-4">
          <h3 className="font-medium">
            {editing.name} on {host.name}
          </h3>
          <p className="text-xs text-muted-foreground">
            These are saved settings, not a model reported by the agent. Save
            preserves the process; restart applies configuration.
          </p>
          <label className="block text-sm" htmlFor="fleet-unit-model">
            Model
            <Input
              id="fleet-unit-model"
              value={model}
              disabled={busy}
              onChange={(e) => setModel(e.target.value)}
            />
          </label>
          <label className="block text-sm" htmlFor="fleet-unit-prompt">
            System prompt
            <Textarea
              id="fleet-unit-prompt"
              rows={6}
              value={prompt}
              disabled={busy}
              onChange={(e) => setPrompt(e.target.value)}
            />
          </label>
          <div className="flex flex-wrap gap-2">
            <Button disabled={busy} onClick={() => void change("save")}>
              Save settings
            </Button>
            {(["start", "restart", "stop"] as const).map((action) => (
              <Button
                key={action}
                variant="outline"
                disabled={busy}
                onClick={() => void change(action)}
              >
                {action}
              </Button>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}
