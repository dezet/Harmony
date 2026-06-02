import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createProject, getProject, getProjects, updateProject } from "@/lib/api";
import type { Project, ProjectInput } from "@/types/contract";

const PROJECTS_KEY = ["projects"] as const;

export function useProjects() {
  return useQuery<Project[]>({ queryKey: PROJECTS_KEY, queryFn: getProjects });
}

export function useProject(id: string | undefined) {
  return useQuery<Project>({
    queryKey: ["project", id],
    queryFn: () => getProject(id as string),
    enabled: !!id,
  });
}

export function useCreateProject() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: ProjectInput) => createProject(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: PROJECTS_KEY }),
  });
}

export function useUpdateProject(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: ProjectInput) => updateProject(id, input),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: PROJECTS_KEY });
      qc.invalidateQueries({ queryKey: ["project", id] });
    },
  });
}
