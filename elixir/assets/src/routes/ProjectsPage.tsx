import { useEffect } from "react";
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
    <div className="flex items-center justify-between gap-[18px] max-[600px]:flex-wrap max-[600px]:gap-2.5">
      <div className="min-w-0">
        <h1 className="text-title max-[1150px]:text-[26px] max-[600px]:text-[27px]">Projekty</h1>
        <p className="mt-2 text-xs leading-[1.6] text-muted-foreground">
          Repozytoria i projekty Linear, z którymi pracuje Harmony.
        </p>
      </div>
      <Button render={<Link to="/projects/new">Nowy projekt</Link>} />
    </div>
  );
}

export function ProjectsPage() {
  const { data, isLoading, isError, error } = useProjects();
  const projects = data ?? [];

  useEffect(() => {
    document.title = "Projekty — Harmony";
  }, []);

  if (isError) {
    const message = error instanceof Error ? error.message : "Nieoczekiwany błąd";

    return (
      <div className="space-y-4">
        <ProjectListHeader />
        <Alert variant="destructive">
          <AlertTitle>Nie udało się wczytać projektów</AlertTitle>
          <AlertDescription>{message}</AlertDescription>
        </Alert>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <ProjectListHeader />

      {isLoading ? (
        <Skeleton aria-label="Wczytywanie projektów" className="h-24 w-full" />
      ) : projects.length === 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>Brak skonfigurowanych projektów</CardTitle>
            <CardDescription>
              Utwórz projekt, aby powiązać Harmony z repozytorium i projektem Linear.
            </CardDescription>
          </CardHeader>
        </Card>
      ) : (
        <div className="rounded-[10px] border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Projekt</TableHead>
                <TableHead>Repozytorium</TableHead>
                <TableHead>Gałąź bazowa</TableHead>
                <TableHead>Linear</TableHead>
                <TableHead>Wersja</TableHead>
                <TableHead>
                  <span className="sr-only">Akcje</span>
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {projects.map((p) => {
                const name = p.display_name ?? p.slug;
                return (
                  <TableRow key={p.id}>
                    <TableCell>
                      <Link className="font-[550] underline-offset-2 hover:underline" to={`/projects/${p.slug}`}>
                        {name}
                      </Link>
                      {p.display_name ? <span className="ml-2 font-mono text-xs text-muted-foreground">{p.slug}</span> : null}
                    </TableCell>
                    <TableCell>{`${p.github_owner}/${p.github_repo}`}</TableCell>
                    <TableCell>{p.github_base_branch}</TableCell>
                    <TableCell>{p.linear_project_slug ?? "—"}</TableCell>
                    <TableCell>{p.config_version}</TableCell>
                    <TableCell>
                      <Link className="underline" to={`/projects/${p.id}/edit`} aria-label={`Edytuj projekt ${name}`}>
                        Edytuj
                      </Link>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}
