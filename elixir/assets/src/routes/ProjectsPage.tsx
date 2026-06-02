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

export function ProjectsPage() {
  const { data, isLoading } = useProjects();

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">Projects</h1>
        <Button render={<Link to="/projects/new">New project</Link>} />
      </div>

      {isLoading ? (
        <Skeleton className="h-24 w-full" />
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
            {(data ?? []).map((p) => (
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
