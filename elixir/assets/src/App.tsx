import { Routes, Route } from "react-router-dom";
import { AppShell } from "@/components/layout/AppShell";
import { OverviewPage } from "@/features/overview/OverviewPage";
import { RuntimePage } from "@/features/runtime/RuntimePage";
import { ProjectsPage } from "@/routes/ProjectsPage";
import { ProjectFormPage } from "@/routes/ProjectFormPage";
import { NotFoundPage } from "@/routes/NotFoundPage";
import { ProjectWorkspacePage } from "@/features/project/ProjectWorkspacePage";
import { RunDetailPage } from "@/features/run/RunDetailPage";

export function AppRoutes() {
  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<OverviewPage />} />
        <Route path="runtime" element={<RuntimePage />} />
        <Route path="projects" element={<ProjectsPage />} />
        <Route path="projects/new" element={<ProjectFormPage />} />
        <Route path="projects/:slug" element={<ProjectWorkspacePage />} />
        <Route path="projects/:slug/runs/:identifier" element={<RunDetailPage />} />
        <Route path="projects/:id/edit" element={<ProjectFormPage />} />
        <Route path="*" element={<NotFoundPage />} />
      </Route>
    </Routes>
  );
}
