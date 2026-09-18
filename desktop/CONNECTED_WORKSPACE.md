# Connected workspace — experimental fork

This extends Buzz's existing client rather than replacing the relay. The intentional product departure from `VISION_REMOTE_AGENTS.md` is ongoing direct host management.

## Apps

An app record has an id, display name, entry URL, optional channel shortcut, adapter (`web` or `parachute`), and optional Nostr-authenticated MCP endpoint. The remote webview is origin-confined and ephemeral. It receives no host-control IPC, private key, or ambient access to the client. Opening/closing the view does not grant anyone service access. The app supplies its real UI.

Parachute's existing `/api/auth/nostr/challenge` and `/verify` endpoints supply browser sign-in. The client verifies the exact login statement and origin before signing; HttpOnly cookies stay in native/browser storage. Two-factor authentication is completed in Parachute. Keys must already be linked to a Parachute account. The service-tools panel uses separate NIP-98 request signatures as the human. It can discover the service's actual tools and explicitly call them, including access-grant tools when authorized. This is not automatic agent MCP installation.

The current MCP adapter supports stateless JSON responses, such as Parachute's `/account/mcp`. OAuth, streamed/sessionful MCP, and cross-origin OAuth popups are not supported yet. Remote HTTPS and loopback HTTP are permitted; credentials embedded in URLs are rejected.

Connection records use encrypted-to-self NIP-78 events (kind 30078), one `d` tag per record, on the current community's existing relay. Different additions cannot overwrite each other. Deletion is a tombstone. No host command or saved agent configuration travels through these events. Device-local caches are identity/community scoped. Another device still needs its own authorized route to the host; SSH credentials are never synced.

## Fleet

The separate buzz-host branch `astra/fleet-management` provides `buzz-host manage`: one JSON request on stdin, one versioned JSON response on stdout. It exposes redacted inventory, saved model/prompt editing, and start/restart/stop per named unit. Settings revisions fence writes and every operation consumes a revision. Requests expire rather than sitting in an offline queue. Save does not restart; the UI offers restart separately with confirmation. A saved setting is not a claim that the harness accepted a model. `process_running` is a process observation, not health.

Local and SSH connections use the same command. The OS account authorizes management; this version does not implement Nostr-based host operator ACLs or view-only OS credentials. Never infer management permission from channel membership. Remote hosts need the updated binary installed by an operator. Connecting a host only inspects already-installed units; it does not redeploy them.

## Isolated build

Use `BUZZ_BUILD_DEMO_SLUG=connected-lab` and the `src-tauri/tauri.connected.json` override. The experimental identifier, keyring, agent-config home, and deep-link scheme must stay separate from production. Sidecars are intentionally excluded from this development configuration; it is for conversations, connected apps, and external buzz-host management, not spawning bundled local ACP runtimes.

From the repository root:

```sh
. ./bin/activate-hermit
env -u BUZZ_BUILD_AUTO_CONNECT_DEFAULT_RELAY -u BUZZ_PRIVATE_KEY -u BUZZ_AUTH_TAG \
  BUZZ_BUILD_DEMO_SLUG=connected-lab \
  pnpm --dir desktop tauri build --debug --config src-tauri/tauri.connected.json --bundles app
```

The auto-connect build flag is presence-only: setting it to `false` still enables
it, so the lab command removes it. Do not replace the production application or
host binary. In the lab, explicitly sign in and choose a community, open **Apps &
fleet**, then add a Parachute URL or inspect a host using its absolute experimental
binary path. A local test host should use an isolated state directory and unique
unit names. Stop is not a persistent disable across reboot.

## Remaining acceptance work

Full native session/cookie walkthrough, end-to-end service grants with disposable identities, cross-device live relay sync, Linux supervisor parity, native UI screenshots and build packaging. Mobile transport, automatic SSH/bootstrap provisioning, app distribution/signing, and OS-independent shared operator roles remain separate follow-on scope. No production host or client replacement is part of this experiment.
