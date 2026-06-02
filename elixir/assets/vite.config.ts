import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";

// The SPA is served by Phoenix from priv/static/app under the /app base path
// during Phases 0-2. Phase 3 flips `base` to "/".
export default defineConfig({
  base: "/app/",
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { "@": path.resolve(import.meta.dirname, "./src") },
  },
  build: {
    outDir: "../priv/static/app",
    emptyOutDir: true,
  },
  server: {
    proxy: {
      "/api": {
        target: `http://localhost:${process.env.HARMONY_PORT ?? "4000"}`,
        changeOrigin: true,
      },
      "/socket": {
        target: `http://localhost:${process.env.HARMONY_PORT ?? "4000"}`,
        ws: true,
        changeOrigin: true,
      },
    },
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: "./src/test/setup.ts",
    css: true,
  },
});
