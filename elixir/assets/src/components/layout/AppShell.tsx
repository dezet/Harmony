import { Link, Outlet } from "react-router-dom";

export function AppShell() {
  return (
    <div className="min-h-screen bg-background text-foreground">
      <nav className="border-b px-6 py-3 flex gap-4">
        <Link to="/">Dashboard</Link>
        <Link to="/projects">Projects</Link>
      </nav>
      <main className="p-6">
        <Outlet />
      </main>
    </div>
  );
}
