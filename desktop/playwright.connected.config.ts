import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "connected-workspace.spec.ts",
  timeout: 120000,
  workers: 1,
  use: {
    launchOptions: { executablePath: process.env.BUZZ_CONNECTED_CHROMIUM },
    baseURL: "http://127.0.0.1:4178",
    viewport: { width: 1440, height: 1000 },
    screenshot: "only-on-failure",
  },
  webServer: {
    command: "python3 -m http.server 4178 -d dist",
    url: "http://127.0.0.1:4178",
    reuseExistingServer: false,
  },
});
