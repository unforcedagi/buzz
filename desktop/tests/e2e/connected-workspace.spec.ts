import { expect, test } from "@playwright/test";
import { installMockBridge } from "../helpers/bridge";
import { waitForAnimations } from "../helpers/animations";

test("connects an app and inspects a host without deploying; rejects an unconfirmed action", async ({
  page,
}) => {
  await installMockBridge(page);
  await page.goto("/");
  await expect(page.getByTestId("connected-workspace-toggle")).toBeVisible({
    timeout: 30000,
  });
  await page.evaluate(() => {
    const target = window as unknown as {
      __TAURI_INTERNALS__: {
        invoke: (
          command: string,
          args?: Record<string, unknown>,
        ) => Promise<unknown>;
      };
      fleetCalls: unknown[];
    };
    const previous = target.__TAURI_INTERNALS__.invoke;
    target.fleetCalls = [];
    target.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command.startsWith("connected_app_")) return null;
      if (command === "fleet_request") {
        target.fleetCalls.push(args);
        return {
          protocol: 1,
          ok: true,
          observed_at: 1700000000,
          units: [
            {
              name: "test-copy",
              revision: "revision-1",
              pubkey: null,
              relay_url: "wss://test.example",
              model: "test-model",
              system_prompt: "Test",
              process_running: true,
            },
          ],
        };
      }
      return previous(command, args);
    };
  });
  await page.getByTestId("connected-workspace-toggle").click();
  await page.getByLabel("Name", { exact: true }).fill("Project notes");
  await page
    .getByLabel("HTTPS app or project URL")
    .fill("https://notes.example/project");
  await page.getByRole("button", { name: "Add shortcut" }).click();
  await expect(
    page.getByRole("heading", { name: "Project notes" }),
  ).toBeVisible();
  await waitForAnimations(page);
  await page.screenshot({ path: "test-results/connected-apps.png" });
  await page.getByRole("button", { name: "Fleet", exact: true }).click();
  await page.getByText("Connect a host", { exact: true }).click();
  await page.getByLabel("Host name", { exact: true }).fill("Test machine");
  await page
    .getByLabel("Absolute buzz-host path on that machine")
    .fill("/tmp/test/buzz-host");
  await page.getByRole("button", { name: "Inspect and connect" }).click();
  await expect(page.getByRole("button", { name: /test-copy/ })).toBeVisible();
  await page.getByRole("button", { name: /test-copy/ }).click();
  await expect(page.getByLabel("Model", { exact: true })).toHaveValue(
    "test-model",
  );
  page.on("dialog", (dialog) => dialog.dismiss());
  await page.getByRole("button", { name: "restart", exact: true }).click();
  const calls = await page.evaluate(
    () =>
      (window as unknown as { fleetCalls: { request: { op: string } }[] })
        .fleetCalls,
  );
  expect(calls.map((call) => call.request.op)).toEqual(["inventory"]);
  await waitForAnimations(page);
  await page.screenshot({ path: "test-results/connected-fleet.png" });
});
