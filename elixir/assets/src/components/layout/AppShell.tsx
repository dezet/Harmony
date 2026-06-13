import { Outlet } from "react-router-dom";
import { Breadcrumbs } from "@/components/layout/Breadcrumbs";
import { Sidebar } from "@/components/layout/Sidebar";

export function AppShell() {
  return (
    <div className="flex h-screen bg-background text-foreground">
      <Sidebar />
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-12 shrink-0 items-center border-b px-6">
          <Breadcrumbs />
        </header>
        <main className="flex-1 overflow-y-auto p-6">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
