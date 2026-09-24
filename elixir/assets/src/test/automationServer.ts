import { vi } from "vitest";
import type {
  AutomationPreview,
  AutomationRule,
  IntegrationConnection,
  JiraPickerItem,
  LinearOptions,
  Project,
} from "@/types/contract";

// In-memory intake API for the automation screens. Every request is recorded;
// a test replaces a single route with `on()` to model an error or a race. The
// rule store is mutable, so a refetch returns what the backend would return
// after the mutation, never a canned response.

export const PROJECT_ID = "11111111-1111-4111-8111-111111111111";
export const JIRA_ID = "22222222-2222-4222-8222-222222222222";
export const SMTP_ID = "88888888-8888-4888-8888-888888888888";
export const SMS_ID = "99999999-9999-4999-8999-999999999999";
export const TEAM_ID = "33333333-3333-4333-8333-333333333333";
export const TEAM_NO_TODO_ID = "33333333-0000-4333-8333-333333333333";
export const TEAM_NO_LABEL_ID = "33333333-1111-4333-8333-333333333333";
export const LINEAR_PROJECT_ID = "44444444-4444-4444-8444-444444444444";
export const LINEAR_PROJECT_NO_LABEL_ID = "44444444-1111-4444-8444-444444444444";
export const TODO_STATE_ID = "66666666-6666-4666-8666-666666666666";
export const HOLD_LABEL_ID = "77777777-7777-4777-8777-777777777777";
export const RULE_ID = "55555555-5555-4555-8555-555555555555";
export const NEW_RULE_ID = "55555555-0000-4555-8555-555555555555";
export const OTHER_PROJECT_ID = "11111111-2222-4111-8111-111111111111";

export const PROJECTS: Project[] = [
  {
    id: PROJECT_ID,
    slug: "portal-klienta",
    display_name: "Portal klienta",
    ui_color: "purple",
    linear_project_slug: null,
    linear_team_key: null,
    linear_human_review_state: null,
    github_owner: "acme",
    github_repo: "portal",
    github_base_branch: "main",
    forge_type: "github",
    forge_base_url: null,
    forge_secret: "unset",
    tracker_secret: "unset",
    config_version: 1,
    config: {},
    inserted_at: "2026-09-01T00:00:00Z",
    updated_at: "2026-09-01T00:00:00Z",
  },
  {
    id: OTHER_PROJECT_ID,
    slug: "finanse",
    display_name: "Finanse",
    ui_color: "gold",
    linear_project_slug: null,
    linear_team_key: null,
    linear_human_review_state: null,
    github_owner: "acme",
    github_repo: "finanse",
    github_base_branch: "main",
    forge_type: "github",
    forge_base_url: null,
    forge_secret: "unset",
    tracker_secret: "unset",
    config_version: 1,
    config: {},
    inserted_at: "2026-09-01T00:00:00Z",
    updated_at: "2026-09-01T00:00:00Z",
  },
];

function connection(id: string, kind: IntegrationConnection["kind"], name: string): IntegrationConnection {
  return {
    id,
    kind,
    name,
    settings: {},
    secret_state: "set",
    secret_version: 1,
    enabled: true,
    last_checked_at: null,
    health: "ok",
    error_code: null,
    lock_version: 1,
  };
}

export const CONNECTIONS: IntegrationConnection[] = [
  connection(JIRA_ID, "jira_cloud", "Jira · Electrum"),
  connection(SMTP_ID, "smtp", "Poczta dyżurna"),
  connection(SMS_ID, "smsapi", "SMSAPI dyżur"),
];

export const BOARDS_PAGE_1: JiraPickerItem[] = [
  { id: "42", name: "Wsparcie / Portal klienta" },
  { id: "43", name: "Finanse / Zgłoszenia" },
];
export const BOARDS_PAGE_2: JiraPickerItem[] = [{ id: "44", name: "HR / Wsparcie" }];
export const FILTERS: JiraPickerItem[] = [{ id: "10010", name: "Pilne portalu" }];
export const PRIORITIES: JiraPickerItem[] = [
  { id: "1", name: "Krytyczny" },
  { id: "2", name: "Wysoki" },
  { id: "3", name: "Średni" },
];

export const LINEAR_OPTIONS: LinearOptions = {
  teams: [
    { id: TEAM_ID, key: "POR", name: "Portal", todo_state_id: TODO_STATE_ID, hold_label_id: HOLD_LABEL_ID },
    { id: TEAM_NO_TODO_ID, key: "FIN", name: "Finanse", todo_state_id: null, hold_label_id: null },
    { id: TEAM_NO_LABEL_ID, key: "HR", name: "Kadry", todo_state_id: "66666666-1111-4666-8666-666666666666", hold_label_id: null },
  ],
  projects: [
    { id: LINEAR_PROJECT_ID, name: "Portal klienta", team_ids: [TEAM_ID] },
    { id: LINEAR_PROJECT_NO_LABEL_ID, name: "Kadry", team_ids: [TEAM_NO_LABEL_ID] },
  ],
  states: [{ id: TODO_STATE_ID, name: "Todo", type: "unstarted", team_id: TEAM_ID }],
  hold_label: { name: "harmony:analysis-only" },
  truncated: false,
};

export function makeRule(patch: Partial<AutomationRule> = {}): AutomationRule {
  return {
    id: RULE_ID,
    project_id: PROJECT_ID,
    jira_connection_id: JIRA_ID,
    name: "Pilne zgłoszenia",
    source_type: "board",
    source_id: "42",
    priority_ids: ["1", "2"],
    priority_ranking: null,
    interval_seconds: 300,
    initial_policy: "new_matches_only",
    linear_team_id: TEAM_ID,
    linear_project_id: LINEAR_PROJECT_ID,
    linear_todo_state_id: TODO_STATE_ID,
    linear_hold_label_id: HOLD_LABEL_ID,
    email_connection_id: null,
    sms_connection_id: null,
    email_recipients: [],
    sms_recipients: [],
    enabled: false,
    config_version: 1,
    activation_status: "idle",
    activated_at: null,
    baseline_complete_at: null,
    baseline_generation: null,
    last_started_at: null,
    last_success_at: null,
    next_poll_at: null,
    last_error_code: null,
    lease_until: null,
    lock_version: 1,
    ...patch,
  };
}

export function makePreview(rule: AutomationRule, patch: Partial<AutomationPreview> = {}): AutomationPreview {
  return {
    rule_id: rule.id,
    config_version: rule.config_version,
    sample: [
      {
        jira_issue_id: "10001",
        key: "OPS-142",
        title: "Eksport raportu zwraca błąd 500",
        priority_id: "1",
        priority_name: "Krytyczny",
        status_name: "Do zrobienia",
        url: "https://electrum.atlassian.net/browse/OPS-142",
        already_linked: false,
      },
      {
        jira_issue_id: "10002",
        key: "OPS-145",
        title: "Logowanie przez SSO nie działa",
        priority_id: "2",
        priority_name: "Wysoki",
        status_name: "W toku",
        url: "https://electrum.atlassian.net/browse/OPS-145",
        already_linked: true,
      },
    ],
    sample_limit: 20,
    match_count: 2,
    truncated: false,
    warnings: [{ code: "already_linked", count: 1 }],
    ...patch,
  };
}

export interface Call {
  method: string;
  path: string;
  search: URLSearchParams;
  body: unknown;
}

type Reply = Response | Promise<Response>;
type Handler = (call: Call) => Reply;

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

export function apiError(status: number, code: string, fields: Record<string, string[]> = {}): Response {
  return json({ error: { code, message: code, fields } }, status);
}

export interface AutomationServer {
  rules: Map<string, AutomationRule>;
  calls: Call[];
  on: (route: string, handler: Handler) => void;
  mutations: () => Call[];
  requests: (method: string, path: string) => Call[];
}

const API = "/api/v1";

export function installAutomationServer(initialRules: AutomationRule[] = []): AutomationServer {
  const rules = new Map(initialRules.map((rule) => [rule.id, rule]));
  const calls: Call[] = [];
  const overrides = new Map<string, Handler>();

  const defaults = (call: Call): Reply => {
    const { method, path, search } = call;
    const body = (call.body ?? {}) as Record<string, unknown>;

    if (method === "GET" && path === `${API}/csrf`) return json({ csrf_token: "csrf-test" });
    if (method === "GET" && path === `${API}/projects`) return json({ projects: PROJECTS });
    if (method === "GET" && path === `${API}/integrations`) {
      return json({ items: CONNECTIONS, meta: { next_cursor: null, page_size: 100 } });
    }
    if (method === "GET" && path === `${API}/integrations/${JIRA_ID}/jira/boards`) {
      const q = (search.get("q") ?? "").toLowerCase();
      if (search.get("cursor") === "boards-2") return json({ items: BOARDS_PAGE_2, meta: { next_cursor: null } });
      const items = BOARDS_PAGE_1.filter((item) => item.name.toLowerCase().includes(q));
      return json({ items, meta: { next_cursor: q ? null : "boards-2" } });
    }
    if (method === "GET" && path === `${API}/integrations/${JIRA_ID}/jira/filters`) {
      return json({ items: FILTERS, meta: { next_cursor: null } });
    }
    if (method === "GET" && path === `${API}/integrations/${JIRA_ID}/jira/priorities`) {
      return json({ items: PRIORITIES, meta: { next_cursor: null } });
    }
    if (method === "GET" && path === `${API}/projects/${PROJECT_ID}/linear-options`) return json(LINEAR_OPTIONS);
    if (method === "POST" && path === `${API}/projects/${PROJECT_ID}/linear-hold-label`) {
      return json({ label_id: "77777777-0000-4777-8777-777777777777", created: true }, 201);
    }
    if (method === "GET" && path === `${API}/automations`) {
      return json({ items: [...rules.values()], meta: { next_cursor: null, page_size: 25 } });
    }
    if (method === "POST" && path === `${API}/automations`) {
      const rule = makeRule({ ...(body as Partial<AutomationRule>), id: NEW_RULE_ID });
      rules.set(rule.id, rule);
      return json({ rule }, 201);
    }

    const match = path.match(/^\/api\/v1\/automations\/([^/]+)(?:\/(\w+))?$/);
    const rule = match ? rules.get(match[1]) : undefined;
    if (match && !rule) return apiError(404, "not_found");
    if (match && rule) {
      const action = match[2];
      if (method === "GET" && !action) return json({ rule });
      if (method === "PATCH" && !action) {
        const { version, ...attrs } = body;
        if (version !== rule.config_version) return apiError(409, "stale_version");
        const next = { ...rule, ...(attrs as Partial<AutomationRule>), config_version: rule.config_version + 1 };
        rules.set(rule.id, next);
        return json({ rule: next });
      }
      if (method === "POST" && action === "preview") return json(makePreview(rule));
      if (method === "POST" && action === "activate") {
        const next: AutomationRule = { ...rule, activation_status: "activating", activated_at: "2026-09-24T10:00:00Z" };
        rules.set(rule.id, next);
        return json({ status: "activating", rule: next }, 202);
      }
      if (method === "POST" && action === "pause") {
        const next: AutomationRule = { ...rule, enabled: false, activation_status: "idle", next_poll_at: null };
        rules.set(rule.id, next);
        return json({ rule: next });
      }
      if (method === "POST" && action === "check") {
        return json({ status: "accepted", rule_id: rule.id, scan_id: "scan-1" }, 202);
      }
    }
    return apiError(404, "not_found");
  };

  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input), "http://localhost");
      const method = (init?.method ?? "GET").toUpperCase();
      const body = typeof init?.body === "string" && init.body ? JSON.parse(init.body) : undefined;
      const call: Call = { method, path: url.pathname, search: url.searchParams, body };
      calls.push(call);
      const handler = overrides.get(`${method} ${url.pathname}`) ?? defaults;
      return handler(call);
    }),
  );

  return {
    rules,
    calls,
    on: (route, handler) => overrides.set(route, handler),
    mutations: () => calls.filter((call) => call.method !== "GET"),
    requests: (method, path) => calls.filter((call) => call.method === method && call.path === path),
  };
}
