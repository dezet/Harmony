import { useMutation } from "@tanstack/react-query";
import { listForgeRepositories, listTrackerProjects } from "@/lib/api";
import type {
  ForgeRepositoriesRequest,
  ForgeRepositoriesResponse,
  TrackerProjectsRequest,
  TrackerProjectsResponse,
} from "@/types/contract";

// Lazy: triggered when a picker opens, not on mount.
export function useForgeRepositories() {
  return useMutation<ForgeRepositoriesResponse, Error, ForgeRepositoriesRequest>({
    mutationFn: (body) => listForgeRepositories(body),
  });
}

export function useTrackerProjects() {
  return useMutation<TrackerProjectsResponse, Error, TrackerProjectsRequest>({
    mutationFn: (body) => listTrackerProjects(body),
  });
}
