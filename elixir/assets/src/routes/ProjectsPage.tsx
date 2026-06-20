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
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
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
        <Alert variant="destructive">
          <AlertTitle>Could not load projects</AlertTitle>
          <AlertDescription>{message}</AlertDescription>
        </Alert>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <ProjectListHeader />

      {isLoading ? (
        <Skeleton className="h-24 w-full" />
      ) : projects.length === 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>No projects configured</CardTitle>
            <CardDescription>
              Create a project to map Harmony to a GitHub repository and Linear project.
            </CardDescription>
          </CardHeader>
        </Card>
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
