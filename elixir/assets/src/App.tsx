import { Routes, Route } from "react-router-dom";
import { AppShell } from "@/components/layout/AppShell";
import { OverviewPage } from "@/features/overview/OverviewPage";
import { ProjectsPage } from "@/routes/ProjectsPage";
import { ProjectFormPage } from "@/routes/ProjectFormPage";
import { NotFoundPage } from "@/routes/NotFoundPage";

export function AppRoutes() {
  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<OverviewPage />} />
        <Route path="projects" element={<ProjectsPage />} />
        <Route path="projects/new" element={<ProjectFormPage />} />
        <Route path="projects/:id/edit" element={<ProjectFormPage />} />
        <Route path="*" element={<NotFoundPage />} />
      </Route>
    </Routes>
  );
}
