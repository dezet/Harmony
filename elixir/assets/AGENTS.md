# Harmony Frontend — Agent Notes (Codex/others)

See `CLAUDE.md` in this directory for the full guide. Summary:

- React 19 + TypeScript SPA built by Vite into `../priv/static/app`, served by Phoenix.
- Data: React Query for REST (`src/lib/api.ts`); Phoenix Channels for live dashboard data
  (`src/lib/socket.ts`) hydrating the React Query cache. No `fetch` in components.
- Forms: React Hook Form + Yup. UI: **shadcn/ui `base-nova` components (Base UI) + Tailwind v4,
  styled with theme A** (the accepted Case Center mockup in `docs/mockups/`, variant A only).
- Theme A replaces the default shadcn theme: tokens live in `src/index.css` (light by default, dark
  as a secondary theme with the same layout). Layout uses Tailwind classes and feature components.
- `src/components/ui/*` is shadcn-generated; do not hand-edit. Check shadcn before writing a custom
  component (`npx shadcn@latest add <name>`).
- Wire-contract types: `src/types/contract.ts`, mirroring `SymphonyElixirWeb.Presenter`.
- Alias `@/*` → `src/*`. Tests: Vitest + RTL (`npm run test -- --run`). Browser E2E:
  `make e2e` from `elixir/`. Build: `mix assets.build` from `elixir/`.
