import type { ApiErrorBody, Project, ProjectInput, StatePayload } from "@/types/contract";

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
