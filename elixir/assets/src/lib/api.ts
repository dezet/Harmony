import type {
  ApiErrorBody,
  Project,
  ProjectActivityPage,
  ProjectArtifactsPage,
  ProjectInput,
  ProjectSummary,
  RunDetail,
  RunStreamPage,
  StatePayload,
  WorkRunFilters,
  WorkRunsPage,
} from "@/types/contract";

export class ApiError extends Error {
  code: string;
  status: number;
  fields?: Record<string, string[]>;

  constructor(status: number, code: string, message: string, fields?: Record<string, string[]>) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.fields = fields;
  }
}

const BASE = "/api/v1";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    headers: { "content-type": "application/json", ...(init?.headers ?? {}) },
    ...init,
  });

  const text = await res.text();
  const data = text ? JSON.parse(text) : null;

  if (!res.ok) {
    const body = data as ApiErrorBody | null;
    const err = body?.error;
    throw new ApiError(
      res.status,
      err?.code ?? "http_error",
      err?.message ?? `Request failed with ${res.status}`,
      err?.fields,
    );
  }

  return data as T;
}

export function getState(): Promise<StatePayload> {
  return request<StatePayload>("/state");
}

export function requestRefresh(): Promise<unknown> {
  return request<unknown>("/refresh", { method: "POST" });
}

export function getProjects(): Promise<Project[]> {
  return request<{ projects: Project[] }>("/projects").then((r) => r.projects);
}

export function getProject(id: string): Promise<Project> {
  return request<{ project: Project }>(`/projects/${id}`).then((r) => r.project);
}

export function createProject(input: ProjectInput): Promise<Project> {
  return request<{ project: Project }>("/projects", {
    method: "POST",
    body: JSON.stringify(input),
  }).then((r) => r.project);
}

export function updateProject(id: string, input: ProjectInput): Promise<Project> {
  return request<{ project: Project }>(`/projects/${id}`, {
    method: "PUT",
    body: JSON.stringify(input),
  }).then((r) => r.project);
}

export function getProjectSummary(ref: string): Promise<ProjectSummary> {
  return request<ProjectSummary>(`/projects/${encodeURIComponent(ref)}/summary`);
}

export function getWorkRuns(
  slug: string,
  filters: WorkRunFilters,
  cursor?: string,
): Promise<WorkRunsPage> {
  const params = new URLSearchParams({ project: slug });
  if (filters.status) params.set("status", filters.status);
  if (cursor) params.set("cursor", cursor);
  return request<WorkRunsPage>(`/work_runs?${params.toString()}`);
}

export function getRunDetail(identifier: string): Promise<RunDetail> {
  return request<RunDetail>(`/runs/${encodeURIComponent(identifier)}`);
}

export function getRunStream(identifier: string, cursor?: string): Promise<RunStreamPage> {
  const params = new URLSearchParams();
  if (cursor) params.set("cursor", cursor);
  const query = params.toString();
  return request<RunStreamPage>(
    `/runs/${encodeURIComponent(identifier)}/stream${query ? `?${query}` : ""}`,
  );
}

export function getProjectArtifacts(slug: string): Promise<ProjectArtifactsPage> {
  return request<ProjectArtifactsPage>(
    `/projects/${encodeURIComponent(slug)}/artifacts`,
  );
}

export function getProjectActivity(slug: string, cursor?: string): Promise<ProjectActivityPage> {
  const params = new URLSearchParams();
  if (cursor) params.set("cursor", cursor);
  const query = params.toString();
  return request<ProjectActivityPage>(
    `/projects/${encodeURIComponent(slug)}/activity${query ? `?${query}` : ""}`,
  );
}

export function getArtifactUrl(id: string): string {
  return `${BASE}/artifacts/${encodeURIComponent(id)}`;
}
