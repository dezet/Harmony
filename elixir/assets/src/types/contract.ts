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

export interface RateLimitBucket {
  used?: number;
  limit?: number;
  reset_at?: string;
  reset_in_ms?: number;
  [key: string]: unknown;
}

export interface RateLimitsPayload {
  limit_id?: string;
  limit_name?: string;
  primary?: RateLimitBucket;
  secondary?: RateLimitBucket;
  credits?: RateLimitBucket;
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
  rate_limits?: RateLimitsPayload | null;
  projects?: Array<ProjectRef & { counts: ProjectCounts }>;
  durable?: Durable;
  error?: StateError;
}

export interface ApiErrorBody {
  error: { code: string; message: string; fields?: Record<string, string[]> };
}

// ─── Project Summary endpoint (/api/v1/projects/:ref/summary) ───────────────

export type SecretState = "set" | "unset";

export interface SummaryProject {
  id: string;
  slug: string;
  github_owner: string;
  github_repo: string;
  github_base_branch: string;
  forge_secret: SecretState;
  tracker_secret: SecretState;
  linear_project_slug: string | null;
  linear_team_key: string | null;
  linear_human_review_state: string | null;
  display_name: string | null;
  ui_color: ProjectColor;
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
  forge_type: string;
  forge_base_url: string | null;
  forge_secret: SecretState;
  tracker_secret: SecretState;
  // Presentation only: `display_name` null shows the slug; the color never
  // encodes project health.
  display_name: string | null;
  ui_color: ProjectColor;
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

// ─── Project Artifacts endpoint (/api/v1/projects/:ref/artifacts) ────────────

export interface ProjectArtifactWorkRun {
  linear_identifier: string | null;
  status: string;
  inserted_at: string;
}

export interface ProjectArtifact {
  id: string;
  kind: string;
  metadata: Record<string, unknown> | null;
  work_run_id: string | null;
  work_run: ProjectArtifactWorkRun | null;
}

export interface ProjectArtifactsPage {
  artifacts: ProjectArtifact[];
}

// ─── Project Activity endpoint (/api/v1/projects/:ref/activity) ──────────────

export interface ProjectActivityPage {
  items: RunStreamItem[];
  meta: {
    next_cursor: string | null;
  };
}

// ─── Intake cases endpoint (/api/v1/cases) ─────────────────────────────────

export type CaseColumn = "detected" | "analyzing" | "decision" | "handed_off";
export type CaseKind = "jira_intake" | "agent_work";
export type ProjectColor = "purple" | "gold" | "teal";
export type CaseExecutionMode = "analysis_only" | "repair_approved" | "existing_workflow";
export type CasePriorityTone = "critical" | "high" | "normal";

export interface CaseProject {
  id: string;
  slug: string;
  name: string;
  color: ProjectColor;
}

export interface CaseJiraLink {
  key: string;
  url: string;
}

export interface CaseLinearLink {
  identifier: string;
  url: string;
}

export interface CasePriority {
  id: string | null;
  label: string;
  tone: CasePriorityTone;
}

export interface CaseAttention {
  code: string;
  message: string;
}

export interface CaseSummary {
  ref: string;
  kind: CaseKind;
  project: CaseProject;
  title: string;
  jira: CaseJiraLink | null;
  linear: CaseLinearLink | null;
  priority: CasePriority;
  column: CaseColumn;
  status_label: string;
  execution_mode: CaseExecutionMode;
  detected_at: string;
  updated_at: string;
  attention: CaseAttention | null;
}

export interface CaseCounts {
  all: number;
  decision: number;
  analysis: number;
  done: number;
  detected: number;
}

export interface CaseProjectCount {
  project_id: string;
  total: number;
}

export interface CasesPage {
  items: CaseSummary[];
  meta: {
    next_cursor: string | null;
    total: number;
    page_size: number;
  };
  counts: CaseCounts;
  project_counts: CaseProjectCount[];
}

// Query of GET /cases; empty values are not sent. `project` is a UUID or slug.
export type CaseListFilter = "all" | "decision" | "analysis" | "done";

export interface CaseFilters {
  project?: string;
  filter?: CaseListFilter;
  column?: CaseColumn;
  q?: string;
  page_size?: number;
}

// `changed` push of the `intake:workspace` channel: identifiers only, never
// content; the client invalidates the matching queries and refetches over REST.
export interface IntakeChangedPayload {
  project_id: string | null;
  case_ref: string | null;
  rule_id: string | null;
  revision: number;
  changed_at: string;
}

export type IntakeCaseStatus = "queued" | "running" | "ready" | "needs_input" | "failed";
export type AnalysisStatus = "queued" | "running" | "succeeded" | "failed" | "needs_input";
export type AnalysisConfidence = "low" | "medium" | "high";
export type AnalysisContextScope = "issue_only" | "issue_and_repository";

export interface CaseRuleSnapshot {
  name: string;
  source_type: "board" | "filter";
  source_id: string;
  priority_ids: string[];
  initial_policy: "new_matches_only" | "include_existing";
  qualified_at: string;
}

export interface CaseDetailCase extends CaseSummary {
  project_id: string;
  rule_id: string;
  jira_connection_id: string;
  jira_issue_id: string;
  description_text: string;
  jira_updated_at: string;
  linear_state_name: string | null;
  analysis_version: number;
  analysis_status: IntakeCaseStatus;
  acknowledged_at: string | null;
  repair_approved_at: string | null;
  repair_approved_version: number | null;
  rule_snapshot: CaseRuleSnapshot;
}

export interface AnalysisInputSnapshot {
  context_scope: AnalysisContextScope;
  jira_key: string;
  repo_sha: string | null;
}

export interface AnalysisFact {
  text: string;
  source: string;
}

export interface AnalysisHypothesis {
  text: string;
  confidence: AnalysisConfidence;
  evidence: string[];
}

export interface AnalysisResult {
  summary: string;
  facts: AnalysisFact[];
  hypotheses: AnalysisHypothesis[];
  missing_data: string[];
  next_steps: string[];
  needs_input: boolean;
  context_scope: AnalysisContextScope;
}

export interface AnalysisTokenUsage {
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
}

export interface CaseAnalysis {
  version: number;
  status: AnalysisStatus;
  input_snapshot: AnalysisInputSnapshot;
  result: AnalysisResult | null;
  model: string;
  effort: string;
  started_at: string | null;
  completed_at: string | null;
  token_usage: AnalysisTokenUsage | null;
  error_code: string | null;
  work_run_id: string | null;
}

export interface CaseDetailLinks {
  jira: CaseJiraLink | null;
  linear: CaseLinearLink | null;
}

export type DeliveryOperation = "linear_create" | "email" | "sms" | "analysis" | "jira_comment";
export type DeliveryStatus = "pending" | "running" | "retry_wait" | "succeeded" | "failed" | "unknown" | "paused";

export interface CaseDelivery {
  id: string;
  operation: DeliveryOperation;
  status: DeliveryStatus;
  attempts: number;
  next_attempt_at: string | null;
  provider_id: string | null;
  first_attempt_at: string | null;
  sent_at: string | null;
  last_error_code: string | null;
  retry_allowed: boolean;
  duplicate_risk: boolean;
}

export interface CaseAction {
  allowed: boolean;
  reason: string | null;
}

export interface CaseActions {
  acknowledge: CaseAction;
  reanalyze: CaseAction;
  approve_repair: CaseAction;
}

export type PublicationStatus = "pending" | "published" | "failed" | "unknown";

export interface CasePublication {
  status: PublicationStatus;
  version: number;
  comment_id: string | null;
  marker: string | null;
  published_at: string | null;
  error_code: string | null;
}

export interface CaseDetail {
  case: CaseDetailCase;
  analysis: CaseAnalysis | null;
  links: CaseDetailLinks;
  deliveries: CaseDelivery[];
  actions: CaseActions;
  publication: CasePublication;
  version: number;
}

export interface CaseWorkRunForge {
  owner: string | null;
  repo: string | null;
  pr_number: number | null;
  head_ref: string | null;
  base_ref: string | null;
}

export interface CaseWorkRun {
  id: string;
  type: string;
  status: string;
  agent_backend: string | null;
  forge: CaseWorkRunForge | null;
}

export interface AgentWorkDetailCase extends CaseSummary {
  project_id: string;
  work_run: CaseWorkRun;
}

// `run_<uuid>` detail: no Jira analysis, deliveries or publication; every
// action is refused with `unsupported_case_kind`.
export interface AgentWorkDetail {
  case: AgentWorkDetailCase;
  analysis: null;
  links: CaseDetailLinks;
  deliveries: CaseDelivery[];
  actions: CaseActions;
  publication: null;
  version: null;
}

export type CaseDetailResponse = CaseDetail | AgentWorkDetail;

// History entry of GET /cases/:ref/events; recipients arrive masked.
export interface CaseEvent {
  id: string;
  type: string;
  actor: "system" | "operator";
  occurred_at: string;
  operation: DeliveryOperation | null;
  recipient: string | null;
  payload: Record<string, unknown>;
}

export interface CaseEventsPage {
  items: CaseEvent[];
  meta: {
    next_cursor: string | null;
    page_size: number;
  };
}

// ─── Automation and integration endpoints ──────────────────────────────────

export type AutomationSourceType = "board" | "filter";
export type AutomationInitialPolicy = "new_matches_only" | "include_existing";
export type AutomationActivationStatus = "idle" | "activating" | "error";

export interface AutomationRule {
  id: string;
  project_id: string;
  jira_connection_id: string;
  name: string;
  source_type: AutomationSourceType;
  source_id: string;
  priority_ids: string[];
  // Jira priority IDs in the order of the Jira response, stored at activation;
  // null = no ranking known (every Jira priority tone is then "normal").
  priority_ranking: string[] | null;
  interval_seconds: number;
  initial_policy: AutomationInitialPolicy;
  linear_team_id: string;
  linear_project_id: string;
  linear_todo_state_id: string;
  linear_hold_label_id: string;
  email_connection_id: string | null;
  sms_connection_id: string | null;
  email_recipients: string[];
  sms_recipients: string[];
  enabled: boolean;
  config_version: number;
  activation_status: AutomationActivationStatus;
  activated_at: string | null;
  baseline_complete_at: string | null;
  baseline_generation: string | null;
  last_started_at: string | null;
  last_success_at: string | null;
  next_poll_at: string | null;
  last_error_code: string | null;
  lease_until: string | null;
  lock_version: number;
}

export type IntegrationKind = "jira_cloud" | "smtp" | "smsapi";
export type IntegrationHealth = "unchecked" | "ok" | "error";

export interface IntegrationConnection {
  id: string;
  kind: IntegrationKind;
  name: string;
  settings: Record<string, unknown>;
  secret_state: SecretState;
  secret_version: number;
  enabled: boolean;
  last_checked_at: string | null;
  health: IntegrationHealth;
  error_code: string | null;
  lock_version: number;
}

// ─── Intake API requests and responses (spec §11.2) ────────────────────────

export interface ApiPageMeta {
  next_cursor: string | null;
  page_size?: number;
}

export interface ApiPage<T> {
  items: T[];
  meta: ApiPageMeta;
}

// GET /integrations: the page meta also carries the runtime
// `intake.smtp_allowed_hosts`, the only SMTP hosts a connection may use.
export interface IntegrationsPageMeta extends ApiPageMeta {
  smtp_allowed_hosts: string[];
}

export interface IntegrationsPage {
  items: IntegrationConnection[];
  meta: IntegrationsPageMeta;
}

export interface CursorQuery {
  cursor?: string;
  page_size?: number;
}

// Filters of the rule list query key; the cursor belongs to the page, not the key.
export interface AutomationFilters {
  project?: string;
  page_size?: number;
}

// Editable automation_rules fields (§6.1); metadata, lease and `enabled` are not input.
export interface AutomationRuleInput {
  name: string;
  project_id: string;
  jira_connection_id: string;
  source_type: AutomationSourceType;
  source_id: string;
  priority_ids: string[];
  interval_seconds: number;
  initial_policy: AutomationInitialPolicy;
  linear_team_id: string;
  linear_project_id: string;
  linear_todo_state_id: string;
  linear_hold_label_id: string;
  email_connection_id: string | null;
  sms_connection_id: string | null;
  email_recipients: string[];
  sms_recipients: string[];
}

// Partial edit; `version` is the rule `config_version` the form was loaded with.
export type AutomationRulePatch = Partial<AutomationRuleInput> & { version: number };

export interface AutomationPreviewSample {
  jira_issue_id: string;
  key: string;
  title: string;
  priority_id: string | null;
  priority_name: string | null;
  status_name: string | null;
  url: string | null;
  already_linked: boolean;
}

export interface AutomationPreviewWarning {
  code: "already_linked" | "source_conflict" | "include_existing_import";
  count?: number;
  rules?: { rule_id: string; project_id: string }[];
}

export interface AutomationPreview {
  rule_id: string;
  config_version: number;
  sample: AutomationPreviewSample[];
  sample_limit: number;
  match_count: number;
  truncated: boolean;
  warnings: AutomationPreviewWarning[];
}

export interface AutomationActivation {
  status: "activating" | "enabled" | AutomationActivationStatus;
  rule: AutomationRule;
}

export interface AutomationCheck {
  status: "accepted";
  rule_id: string;
  scan_id: string;
}

export interface AutomationBulkCheck {
  accepted_rule_ids: string[];
  skipped: { rule_id: string; code: string }[];
}

export interface IntegrationConnectionInput {
  kind: IntegrationKind;
  name: string;
  settings: Record<string, unknown>;
  secret?: string;
  enabled?: boolean;
}

// `secret: ""` keeps the stored secret; `clear_secret: true` removes it.
export interface IntegrationConnectionPatch {
  version: number;
  name?: string;
  settings?: Record<string, unknown>;
  secret?: string;
  clear_secret?: boolean;
  enabled?: boolean;
}

export interface IntegrationTestResult {
  health: IntegrationHealth;
  checked_at: string;
  error_code: string | null;
}

export interface IntegrationTestSend {
  test_delivery: CaseDelivery;
}

export interface JiraPickerItem {
  id: string;
  name: string;
}

export interface LinearTeamOption {
  id: string;
  key: string;
  name: string;
  todo_state_id: string | null;
  hold_label_id: string | null;
}

export interface LinearProjectOption {
  id: string;
  name: string;
  team_ids: string[];
}

export interface LinearStateOption {
  id: string;
  name: string;
  type: string;
  team_id: string;
}

export interface LinearOptions {
  teams: LinearTeamOption[];
  projects: LinearProjectOption[];
  states: LinearStateOption[];
  hold_label: { name: string };
  truncated: boolean;
}

export interface LinearHoldLabel {
  label_id: string;
  created: boolean;
}

export interface CaseActionState {
  ref: string;
  jira_key: string;
  analysis_version: number;
  analysis_status: IntakeCaseStatus;
  acknowledged_at: string | null;
  repair_approved_at: string | null;
  repair_approved_version: number | null;
  version: number;
}

export interface CaseActionResult {
  case: CaseActionState;
  version: number;
}

export interface CaseApproveResult extends CaseActionResult {
  status: "approved";
}

export interface CaseReanalyzeResult extends CaseActionResult {
  analysis_version: number;
}

// What the project form submits. `config` is an object parsed from the JSON textarea.
export interface ForgeRepository {
  owner: string;
  name: string;
  default_branch: string;
  url: string;
}

export interface ForgeRepositoriesResponse {
  repositories: ForgeRepository[];
  truncated: boolean;
}

export interface TrackerProject {
  id: string;
  name: string;
  slug: string;
  team_key: string;
}

export interface TrackerProjectsResponse {
  projects: TrackerProject[];
  truncated: boolean;
}

export interface ForgeRepositoriesRequest {
  forge_type: string;
  base_url?: string | null;
  token?: string | null;
}

export interface TrackerProjectsRequest {
  token?: string | null;
  base_url?: string | null;
}

export interface ProjectInput {
  slug: string;
  linear_project_slug?: string | null;
  linear_team_key?: string | null;
  linear_human_review_state?: string | null;
  github_owner: string;
  github_repo: string;
  github_base_branch: string;
  forge_type?: string;
  forge_base_url?: string | null;
  // Omitted keys keep the stored value; a null display name falls back to the slug.
  display_name?: string | null;
  ui_color?: ProjectColor;
  config_version: number;
  config: Record<string, unknown>;
  // Write-only secrets: a non-empty value sets it; the clear flag resets to env
  // fallback. The API never echoes a value (reads return only `forge_secret`
  // `"set" | "unset"`).
  forge_secret?: string;
  tracker_secret?: string;
  clear_forge_secret?: boolean;
  clear_tracker_secret?: boolean;
}
