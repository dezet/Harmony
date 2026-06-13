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

export interface DurableProject {
  id: string;
  slug: string;
  linear: {
    project_slug: string | null;
    team_key: string | null;
    human_review_state: string | null;
  };
  github: {
    owner: string;
    repo: string;
    base_branch: string;
  };
  config_version: number;
}

export interface DurableWorkRun {
  id: string;
  project_id: string;
  type: string;
  status: string;
  dedupe_key: string | null;
  github_owner: string | null;
  github_repo: string | null;
  github_pr_number: number | null;
  github_head_sha: string | null;
  github_head_ref: string | null;
  github_base_ref: string | null;
  linear_issue_id: string | null;
  linear_identifier: string | null;
  linear_url: string | null;
  agent_backend: string | null;
  payload: Record<string, unknown> | null;
}

export interface DurablePullRequestLink {
  id: string;
  project_id: string;
  github_owner: string;
  github_repo: string;
  github_pr_number: number;
  github_head_sha: string | null;
  github_head_ref: string | null;
  github_base_ref: string | null;
  linear_issue_id: string | null;
  linear_identifier: string | null;
  linear_url: string | null;
  metadata: Record<string, unknown> | null;
}

export interface DurableBlocker {
  id: string;
  project_id: string | null;
  work_run_id: string | null;
  target_type: string;
  target_id: string;
  reason: string;
  status: string;
  metadata: Record<string, unknown> | null;
}

export interface DurableDedupeKey {
  id: string;
  project_id: string | null;
  key: string;
  scope: string;
  status: string;
  metadata: Record<string, unknown> | null;
}

export interface DurableWorkEvent {
  id: string;
  project_id: string | null;
  work_run_id: string | null;
  type: string;
  payload: Record<string, unknown> | null;
  inserted_at: string | null;
}

export interface DurableArtifact {
  id: string;
  project_id: string | null;
  work_run_id: string | null;
  kind: string | null;
  path: string | null;
  metadata: Record<string, unknown> | null;
}

export interface ArtifactTableRow {
  id?: string;
  kind?: string | null;
  path?: string | null;
}

export interface Durable {
  projects?: DurableProject[];
  work_runs?: DurableWorkRun[];
  pull_request_links?: DurablePullRequestLink[];
  blockers?: DurableBlocker[];
  dedupe_keys?: DurableDedupeKey[];
  work_events?: DurableWorkEvent[];
  artifacts?: DurableArtifact[];
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

// ─── Project Summary endpoint (/api/v1/projects/:ref/summary) ───────────────

export interface SummaryProject {
  id: string;
  slug: string;
  github_owner: string;
  github_repo: string;
  github_base_branch: string;
  linear_project_slug: string | null;
  linear_team_key: string | null;
  linear_human_review_state: string | null;
  config_version: number;
}

export interface HumanReviewPR {
  id: string;
  github_owner: string;
  github_repo: string;
  github_pr_number: number;
  github_head_sha: string | null;
  github_head_ref: string | null;
  github_base_ref: string | null;
  linear_identifier: string | null;
  linear_url: string | null;
  metadata: Record<string, unknown> | null;
}

export interface ProjectSummary {
  project: SummaryProject;
  counts: ProjectCounts;
  running: Omit<RunningEntry, "project">[];
  retrying: Omit<RetryEntry, "project">[];
  blocked: Omit<BlockedEntry, "project">[];
  human_review_prs: HumanReviewPR[];
}

// ─── Work Runs endpoint (/api/v1/work_runs) ──────────────────────────────────

export interface WorkRunListItem {
  id: string;
  project_id: string;
  type: string;
  status: string;
  dedupe_key: string | null;
  github_owner: string | null;
  github_repo: string | null;
  github_pr_number: number | null;
  github_head_sha: string | null;
  github_head_ref: string | null;
  github_base_ref: string | null;
  linear_issue_id: string | null;
  linear_identifier: string | null;
  linear_url: string | null;
  agent_backend: string | null;
  inserted_at: string;
  updated_at: string;
}

export interface WorkRunsPage {
  work_runs: WorkRunListItem[];
  meta: {
    next_cursor: string | null;
    page_size: number;
  };
}

export interface WorkRunFilters {
  status?: string;
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

// ─── Run Detail endpoint (/api/v1/runs/:identifier) ─────────────────────────

export interface RunDetailProject {
  id: string | null;
  slug: string | null;
  name: string | null;
}

export interface RunDetailWorkspace {
  path: string;
  host: string;
}

export interface RunArtifact {
  id: string;
  kind: string | null;
  path: string | null;
  metadata: Record<string, unknown> | null;
}

export interface RunDetail {
  identifier: string;
  issue_id: string | null;
  work_run_id: string | null;
  status: string;
  project: RunDetailProject | null;
  workspace: RunDetailWorkspace | null;
  session_id: string | null;
  turn_count: number;
  started_at: string | null;
  last_event_at: string | null;
  last_event: string | null;
  last_message: string | null;
  tokens: Tokens | null;
  attempts: {
    restart_count: number | null;
    current_retry_attempt: number | null;
  };
  pull_requests: HumanReviewPR[];
  artifacts: RunArtifact[];
  last_error: string | null;
  stream_cursor: string | null;
}

export interface RunStreamItem {
  id: string;
  kind: "work_event" | "live_event";
  type: string;
  at: string;
  payload: Record<string, unknown> | null;
}

export interface RunStreamPage {
  items: RunStreamItem[];
  meta: {
    next_cursor: string | null;
    has_live: boolean;
  };
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
