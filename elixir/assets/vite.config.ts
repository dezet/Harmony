import { configDefaults, defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";

// Backend target for the dev proxy. In host mode this is localhost; in full
// (containerised) mode dev/harmony.sh sets HARMONY_BACKEND_HOST=backend so Vite
// reaches the backend container by its compose service name.
const backendHost = process.env.HARMONY_BACKEND_HOST ?? "localhost";
const backendPort = process.env.HARMONY_PORT ?? "4000";
const backendTarget = `http://${backendHost}:${backendPort}`;

// The SPA is served by Phoenix from priv/static/app at the root path.
// (Phase 3 cutover flipped `base` from "/app/" to "/".)
export default defineConfig({
  base: "/",
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { "@": path.resolve(import.meta.dirname, "./src") },
  },
  build: {
    outDir: "../priv/static/app",
    emptyOutDir: true,
  },
  server: {
    host: true,
    proxy: {
      "/api": {
        target: backendTarget,
        changeOrigin: true,
      },
      "/socket": {
        target: backendTarget,
        ws: true,
        changeOrigin: true,
      },
    },
  },
  test: {
    environment: "jsdom",
    exclude: [...configDefaults.exclude, "e2e/**"],
    globals: true,
    setupFiles: "./src/test/setup.ts",
    css: true,
    pool: "threads",
    maxWorkers: 1,
  },
});
