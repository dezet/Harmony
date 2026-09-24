import type {
  ApiErrorBody,
  ApiPage,
  AutomationActivation,
  AutomationBulkCheck,
  AutomationCheck,
  AutomationPreview,
  AutomationRule,
  AutomationRuleInput,
  AutomationRulePatch,
  CaseActionResult,
  CaseApproveResult,
  CaseDelivery,
  CaseDetailResponse,
  CaseEventsPage,
  CaseFilters,
  CaseReanalyzeResult,
  CasesPage,
  CursorQuery,
  DeliveryStatus,
  ForgeRepositoriesRequest,
  ForgeRepositoriesResponse,
  IntegrationConnection,
  IntegrationConnectionInput,
  IntegrationConnectionPatch,
  IntegrationTestResult,
  IntegrationTestSend,
  JiraPickerItem,
  LinearHoldLabel,
  LinearOptions,
  Project,
  ProjectActivityPage,
  ProjectArtifactsPage,
  ProjectInput,
  ProjectSummary,
  RunDetail,
  RunStreamPage,
  StatePayload,
  TrackerProjectsRequest,
  TrackerProjectsResponse,
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

  return parseResponse<T>(res);
}

async function parseResponse<T>(res: Response): Promise<T> {
  const data = parseJson(await res.text());

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

// Error pages rendered outside a controller (e.g. a malformed body) may not be JSON.
function parseJson(text: string): unknown {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

// ─── Operator mutations (intake API) ───────────────────────────────────────
//
// The session CSRF token is fetched from GET /api/v1/csrf on the first
// mutation and kept only in this module's memory: never in storage, the URL
// or the static index.html. Paths are always relative to BASE, so the token
// is only ever sent to the same-origin API. A 403 from the guard (for example
// after a server restart invalidated the session) drops the token, fetches a
// fresh one and rethrows: the mutation is never repeated automatically, the
// operator has to act again.

const GUARD_REJECTIONS = new Set(["csrf_invalid", "origin_rejected"]);

let csrfToken: string | null = null;
let csrfRequest: Promise<string> | null = null;

async function loadCsrfToken(): Promise<string> {
  const res = await fetch(`${BASE}/csrf`, {
    method: "GET",
    credentials: "same-origin",
    cache: "no-store",
    headers: { accept: "application/json" },
  });
  const data = await parseResponse<{ csrf_token?: unknown } | null>(res);
  const token = data?.csrf_token;
  if (typeof token !== "string" || token === "") {
    throw new ApiError(res.status, "csrf_unavailable", "CSRF token is unavailable");
  }
  return token;
}

function csrf(): Promise<string> {
  if (csrfToken) return Promise.resolve(csrfToken);
  csrfRequest ??= loadCsrfToken()
    .then((token) => {
      csrfToken = token;
      return token;
    })
    .finally(() => {
      csrfRequest = null;
    });
  return csrfRequest;
}

async function operatorMutation<T>(
  method: "POST" | "PATCH",
  path: string,
  body: object = {},
  headers: Record<string, string> = {},
): Promise<T> {
  const token = await csrf();
  const res = await fetch(`${BASE}${path}`, {
    method,
    credentials: "same-origin",
    headers: {
      ...headers,
      accept: "application/json",
      "content-type": "application/json",
      "x-csrf-token": token,
    },
    body: JSON.stringify(body),
  });

  try {
    return await parseResponse<T>(res);
  } catch (error) {
    if (error instanceof ApiError && error.status === 403 && GUARD_REJECTIONS.has(error.code)) {
      csrfToken = null;
      await csrf().catch(() => undefined);
    }
    throw error;
  }
}

function query(params: Record<string, string | number | undefined | null>): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== "") search.set(key, String(value));
  }
  const text = search.toString();
  return text ? `?${text}` : "";
}

const enc = encodeURIComponent;

export function listAutomations(
  params: CursorQuery & { project?: string } = {},
): Promise<ApiPage<AutomationRule>> {
  return request(`/automations${query({ project: params.project, cursor: params.cursor, page_size: params.page_size })}`);
}

export function getAutomation(id: string): Promise<AutomationRule> {
  return request<{ rule: AutomationRule }>(`/automations/${enc(id)}`).then((r) => r.rule);
}

export function createAutomation(input: AutomationRuleInput): Promise<AutomationRule> {
  return operatorMutation<{ rule: AutomationRule }>("POST", "/automations", input).then((r) => r.rule);
}

export function updateAutomation(id: string, patch: AutomationRulePatch): Promise<AutomationRule> {
  return operatorMutation<{ rule: AutomationRule }>("PATCH", `/automations/${enc(id)}`, patch).then(
    (r) => r.rule,
  );
}

export function previewAutomation(id: string): Promise<AutomationPreview> {
  return operatorMutation<AutomationPreview>("POST", `/automations/${enc(id)}/preview`);
}

export function activateAutomation(
  id: string,
  body: { version: number; confirmed: true },
): Promise<AutomationActivation> {
  return operatorMutation<AutomationActivation>("POST", `/automations/${enc(id)}/activate`, body);
}

export function pauseAutomation(id: string, body: { version: number }): Promise<AutomationRule> {
  return operatorMutation<{ rule: AutomationRule }>("POST", `/automations/${enc(id)}/pause`, body).then(
    (r) => r.rule,
  );
}

export function checkAutomation(id: string): Promise<AutomationCheck> {
  return operatorMutation<AutomationCheck>("POST", `/automations/${enc(id)}/check`);
}

export function checkAutomations(body: { project?: string } = {}): Promise<AutomationBulkCheck> {
  return operatorMutation<AutomationBulkCheck>("POST", "/automations/check", body);
}

export function listIntegrations(params: CursorQuery = {}): Promise<ApiPage<IntegrationConnection>> {
  return request(`/integrations${query({ cursor: params.cursor, page_size: params.page_size })}`);
}

export function getIntegration(id: string): Promise<IntegrationConnection> {
  return request<{ connection: IntegrationConnection }>(`/integrations/${enc(id)}`).then((r) => r.connection);
}

export function createIntegration(input: IntegrationConnectionInput): Promise<IntegrationConnection> {
  return operatorMutation<{ connection: IntegrationConnection }>("POST", "/integrations", input).then(
    (r) => r.connection,
  );
}

export function updateIntegration(
  id: string,
  patch: IntegrationConnectionPatch,
): Promise<IntegrationConnection> {
  return operatorMutation<{ connection: IntegrationConnection }>("PATCH", `/integrations/${enc(id)}`, patch).then(
    (r) => r.connection,
  );
}

export function testIntegration(id: string): Promise<IntegrationTestResult> {
  return operatorMutation<IntegrationTestResult>("POST", `/integrations/${enc(id)}/test`);
}

// `idempotencyKey` is a UUID created when the form opens and kept until the
// attempt is settled, so a double click never queues a second message.
export function testSendIntegration(
  id: string,
  body: { recipient: string; confirmed: true; idempotencyKey: string },
): Promise<IntegrationTestSend> {
  return operatorMutation<IntegrationTestSend>(
    "POST",
    `/integrations/${enc(id)}/test-send`,
    { recipient: body.recipient, confirmed: body.confirmed },
    { "idempotency-key": body.idempotencyKey },
  );
}

export function listJiraBoards(
  id: string,
  params: CursorQuery & { q?: string } = {},
): Promise<ApiPage<JiraPickerItem>> {
  return request(`/integrations/${enc(id)}/jira/boards${query({ q: params.q, cursor: params.cursor, page_size: params.page_size })}`);
}

export function listJiraFilters(
  id: string,
  params: CursorQuery & { q?: string } = {},
): Promise<ApiPage<JiraPickerItem>> {
  return request(`/integrations/${enc(id)}/jira/filters${query({ q: params.q, cursor: params.cursor, page_size: params.page_size })}`);
}

export function listJiraPriorities(id: string): Promise<ApiPage<JiraPickerItem>> {
  return request(`/integrations/${enc(id)}/jira/priorities`);
}

export function getLinearOptions(projectId: string): Promise<LinearOptions> {
  return request<LinearOptions>(`/projects/${enc(projectId)}/linear-options`);
}

export function createLinearHoldLabel(
  projectId: string,
  body: { team_id: string; confirmed: true },
): Promise<LinearHoldLabel> {
  return operatorMutation<LinearHoldLabel>("POST", `/projects/${enc(projectId)}/linear-hold-label`, body);
}

// ─── Case Center reads (spec §11.2–11.3) ───────────────────────────────────
// `signal` comes from React Query, so a request of a filter the screen already
// left is aborted instead of landing late.

export function listCases(filters: CaseFilters, cursor?: string, signal?: AbortSignal): Promise<CasesPage> {
  const params = query({
    project: filters.project,
    filter: filters.filter,
    column: filters.column,
    q: filters.q,
    page_size: filters.page_size,
    cursor,
  });
  return request<CasesPage>(`/cases${params}`, { signal });
}

export function getCase(ref: string, signal?: AbortSignal): Promise<CaseDetailResponse> {
  return request<CaseDetailResponse>(`/cases/${enc(ref)}`, { signal });
}

export function listCaseEvents(ref: string, cursor?: string, signal?: AbortSignal): Promise<CaseEventsPage> {
  return request<CaseEventsPage>(`/cases/${enc(ref)}/events${query({ cursor })}`, { signal });
}

export function acknowledgeCase(ref: string, body: { expected_version: number }): Promise<CaseActionResult> {
  return operatorMutation<CaseActionResult>("POST", `/cases/${enc(ref)}/acknowledge`, body);
}

export function approveRepair(
  ref: string,
  body: { expected_version: number; analysis_version: number; confirmed: true },
): Promise<CaseApproveResult> {
  return operatorMutation<CaseApproveResult>("POST", `/cases/${enc(ref)}/approve-repair`, body);
}

export function reanalyzeCase(
  ref: string,
  body: { expected_version: number; confirmed: true },
): Promise<CaseReanalyzeResult> {
  return operatorMutation<CaseReanalyzeResult>("POST", `/cases/${enc(ref)}/reanalyze`, body);
}

export function retryDelivery(
  id: string,
  body: { expected_status: DeliveryStatus; confirm_duplicate_risk?: boolean },
): Promise<CaseDelivery> {
  return operatorMutation<{ delivery: CaseDelivery }>("POST", `/deliveries/${enc(id)}/retry`, body).then(
    (r) => r.delivery,
  );
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

export function listForgeRepositories(
  body: ForgeRepositoriesRequest,
): Promise<ForgeRepositoriesResponse> {
  return request<ForgeRepositoriesResponse>("/forge/repositories", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

export function listTrackerProjects(
  body: TrackerProjectsRequest,
): Promise<TrackerProjectsResponse> {
  return request<TrackerProjectsResponse>("/tracker/projects", {
    method: "POST",
    body: JSON.stringify(body),
  });
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

export function stopRun(identifier: string): Promise<{ status: string }> {
  return request<{ status: string }>(`/runs/${encodeURIComponent(identifier)}/stop`, {
    method: "POST",
  });
}

export function retryRun(identifier: string): Promise<{ status: string }> {
  return request<{ status: string }>(`/runs/${encodeURIComponent(identifier)}/retry`, {
    method: "POST",
  });
}
