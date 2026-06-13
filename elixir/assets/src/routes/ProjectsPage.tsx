import { Link } from "react-router-dom";
import { useProjects } from "@/features/projects/useProjects";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";

function ProjectListHeader() {
  return (
    <div className="flex items-center justify-between">
      <h1 className="text-2xl font-semibold">Projects</h1>
      <Button render={<Link to="/projects/new">New project</Link>} />
    </div>
  );
}

export function ProjectsPage() {
  const { data, isLoading, isError, error } = useProjects();
  const projects = data ?? [];

  if (isError) {
    const message = error instanceof Error ? error.message : "Unexpected error";

    return (
      <div className="space-y-4">
        <ProjectListHeader />
        <div role="alert" className="rounded-md border border-destructive/40 p-4">
          <h2 className="font-medium">Could not load projects</h2>
          <p className="text-sm text-muted-foreground">{message}</p>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <ProjectListHeader />

      {isLoading ? (
        <Skeleton className="h-24 w-full" />
      ) : projects.length === 0 ? (
        <div className="rounded-md border p-6">
          <h2 className="font-medium">No projects configured</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Create a project to map Harmony to a GitHub repository and Linear project.
          </p>
        </div>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Slug</TableHead>
              <TableHead>GitHub</TableHead>
              <TableHead>Base branch</TableHead>
              <TableHead>Linear</TableHead>
              <TableHead>Version</TableHead>
              <TableHead></TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {projects.map((p) => (
              <TableRow key={p.id}>
                <TableCell>{p.slug}</TableCell>
                <TableCell>{`${p.github_owner}/${p.github_repo}`}</TableCell>
                <TableCell>{p.github_base_branch}</TableCell>
                <TableCell>{p.linear_project_slug ?? "—"}</TableCell>
                <TableCell>{p.config_version}</TableCell>
                <TableCell>
                  <Link className="underline" to={`/projects/${p.id}/edit`}>
                    Edit
                  </Link>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
