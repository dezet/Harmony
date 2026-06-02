// Wire-contract types mirroring SymphonyElixirWeb.Presenter.state_payload/0.
// Optional keys use `?` because the Presenter omits projects/durable when empty
// and returns { generated_at, error } on snapshot failure.

export interface ProjectRef {
  id: string | null;
  name: string | null;
  slug: string | null;
}

export interface Tokens {
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
}

export interface RunningEntry {
  issue_id: string;
  issue_identifier: string;
  state: string;
  worker_host: string | null;
  workspace_path: string | null;
  session_id: string | null;
  turn_count: number;
  last_event: string | null;
  last_message: string | null;
  started_at: string | null;
  last_event_at: string | null;
  tokens: Tokens;
  project: ProjectRef | null;
}

export interface RetryEntry {
  issue_id: string;
  issue_identifier: string;
  attempt: number;
  due_at: string | null;
  error: string | null;
  worker_host: string | null;
  workspace_path: string | null;
  project: ProjectRef | null;
}

export interface BlockedEntry {
  issue_id: string;
  issue_identifier: string;
  state: string;
  error: string | null;
  worker_host: string | null;
  workspace_path: string | null;
  session_id: string | null;
  blocked_at: string | null;
  last_event: string | null;
  last_message: string | null;
  last_event_at: string | null;
  project: ProjectRef | null;
}

export interface CodexTotals {
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
  seconds_running: number;
}

export interface SandboxRuntime {
  posture: string | null;
  bubblewrap_available: boolean | null;
  apparmor_restrict_unprivileged_userns: number | null;
  thread_sandbox: string | null;
  turn_sandbox_type: string | null;
  warnings: string[];
}

export interface Runtime {
  sandbox?: SandboxRuntime;
}

export interface Artifact {
  kind?: string;
  path?: string;
  [key: string]: unknown;
}

export interface ProjectCounts {
  running: number;
  retrying: number;
  blocked: number;
}

export interface StateError {
  code: string;
  message: string;
}

export interface DurableWorkRun {
  id: string;
  type: string;
  status: string;
  dedupe_key: string | null;
  github_owner: string | null;
  github_repo: string | null;
  github_pr_number: number | null;
  linear_identifier: string | null;
}

export interface DurableArtifact {
  id?: string;
  kind: string | null;
  path: string | null;
}

export interface Durable {
  work_runs?: DurableWorkRun[];
  artifacts?: DurableArtifact[];
  // Other durable lists (projects, blockers, dedupe_keys, work_events,
  // pull_request_links) exist in the payload but are not rendered yet.
  [key: string]: unknown;
}

export interface StatePayload {
  generated_at: string;
  counts?: ProjectCounts;
  running?: RunningEntry[];
  retrying?: RetryEntry[];
  blocked?: BlockedEntry[];
  runtime?: Runtime;
  artifacts?: Artifact[];
  codex_totals?: CodexTotals;
  rate_limits?: unknown;
  projects?: Array<ProjectRef & { counts: ProjectCounts }>;
  durable?: Durable;
  error?: StateError;
}

export interface ApiErrorBody {
  error: { code: string; message: string; fields?: Record<string, string[]> };
}

export interface Project {
  id: string;
  slug: string;
  linear_project_slug: string | null;
  linear_team_key: string | null;
  linear_human_review_state: string | null;
  github_owner: string;
  github_repo: string;
  github_base_branch: string;
  config_version: number;
  config: Record<string, unknown>;
  inserted_at: string;
  updated_at: string;
}

// What the project form submits. `config` is an object parsed from the JSON textarea.
export interface ProjectInput {
  slug: string;
  linear_project_slug?: string | null;
  linear_team_key?: string | null;
  linear_human_review_state?: string | null;
  github_owner: string;
  github_repo: string;
  github_base_branch: string;
  config_version: number;
  config: Record<string, unknown>;
}
