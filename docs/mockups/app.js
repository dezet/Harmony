"use strict";

// An isolated, offline design prototype. All actions operate on example data only.
const icons = {
  inbox: '<path d="M4 4h16v16H4z"/><path d="M4 14h5l2 3h2l2-3h5"/>',
  grid: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  flow: '<path d="M5 3v12a4 4 0 0 0 4 4h10M5 8h10"/><circle cx="5" cy="4" r="2"/><circle cx="17" cy="8" r="2"/><circle cx="20" cy="19" r="2"/>',
  bolt: '<path d="m13 2-8 12h6l-1 8 9-13h-7z"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  search: '<circle cx="10" cy="10" r="6"/><path d="m15 15 5 5"/>',
  arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  link: '<path d="m10 14 4-4m-6 6-1 1a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0m2 0 1-1a4 4 0 0 1 6 6l-4 4a4 4 0 0 1-6 0"/>',
  settings:
    '<path d="M4 7h16M4 17h16"/><circle cx="9" cy="7" r="3"/><circle cx="15" cy="17" r="3"/>',
  spark:
    '<path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5z"/>',
  bell: '<path d="M6 8a6 6 0 0 1 12 0c0 8 3 8 3 9H3c0-1 3-1 3-9m6 13h2"/>',
  menu: '<path d="M4 6h16M4 12h16M4 18h16"/>',
  close: '<path d="m6 6 12 12M18 6 6 18"/>',
  mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 6 9 7 9-7"/>',
  phone:
    '<rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/>',
  shield:
    '<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6z"/><path d="m8 12 3 3 5-6"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6m0-10v.1"/>',
  folder: '<path d="M3 6h7l2 3h9v11H3z"/>',
};
const icon = (name) =>
  `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.grid}</svg>`;
const escapeHtml = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (ch) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        ch
      ],
  );
const tickets = [
  {
    id: "OPS-142",
    title: "Eksport raportu kończy się błędem 504",
    project: "Portal klienta",
    priority: "Krytyczny",
    status: "decision",
    label: "Analiza gotowa",
    color: "amber",
    age: "12 min",
    linear: "LIN-284",
    summary:
      "Eksport dużego raportu <strong>może przekraczać limit czasu bramy API</strong>. W dostępnym opisie problem dotyczy zakresów powyżej 30 dni. To hipoteza wymagająca potwierdzenia w logach.",
    fact: "Błąd pojawia się przy dużym zakresie dat",
    factDetail:
      "Opis zgłoszenia: raport za 7 dni działa, za 90 dni zwraca 504.",
    hypothesis: "Prawdopodobny limit czasu żądania",
    hypothesisDetail:
      "Brakuje logów bramy i czasu wykonania zapytania. Przyczyna nie jest jeszcze potwierdzona.",
    next: "Zebrać logi dla wskazanego żądania i zmierzyć czas generowania raportu. Następnie zdecydować o przygotowaniu naprawy.",
  },
  {
    id: "OPS-139",
    title: "Brak wiadomości po zresetowaniu hasła",
    project: "Portal klienta",
    priority: "Wysoki",
    status: "analysis",
    label: "Analiza w toku",
    color: "purple",
    age: "4 min",
    linear: "LIN-285",
    summary:
      "Agent porównuje opis zgłoszenia z konfiguracją powiadomień i obsługą resetowania hasła. <strong>Wynik nie jest jeszcze gotowy.</strong>",
    fact: "Użytkownik nie otrzymał wiadomości",
    factDetail: "W zgłoszeniu podano godzinę próby i identyfikator konta.",
    hypothesis: "Weryfikacja kolejki wiadomości",
    hypothesisDetail:
      "Trwa sprawdzanie dostępnych informacji. Brak potwierdzonej przyczyny.",
    next: "Poczekać na zakończenie analizy. Wynik zostanie automatycznie opublikowany w Jira.",
  },
  {
    id: "FIN-87",
    title: "Różnica w sumie faktur po imporcie",
    project: "Finanse",
    priority: "Wysoki",
    status: "decision",
    label: "Brakuje danych",
    color: "amber",
    age: "28 min",
    linear: "LIN-281",
    summary:
      "Zgłoszenie nie zawiera przykładowego pliku ani oczekiwanej kwoty. <strong>Bez tych danych nie da się rozróżnić błędu importu od różnicy w zaokrągleniach.</strong>",
    fact: "Suma importu różni się od sumy źródłowej",
    factDetail: "Zgłaszający opisuje różnicę, ale nie podaje wartości.",
    hypothesis: "Potrzebny przykład rozbieżności",
    hypothesisDetail: "Należy uzyskać zanonimizowany plik i oczekiwany wynik.",
    next: "Poprosić zgłaszającego o przykładowy plik oraz oczekiwaną i otrzymaną kwotę.",
  },
  {
    id: "OPS-145",
    title: "Załącznik nie otwiera się w przeglądarce",
    project: "Portal klienta",
    priority: "Wysoki",
    status: "new",
    label: "Oczekuje na analizę",
    color: "neutral",
    age: "1 min",
    linear: "LIN-286",
    summary:
      "Zgłoszenie zostało wykryte po podniesieniu priorytetu. <strong>Analiza oczekuje na wolnego agenta.</strong>",
    fact: "Priorytet zmieniono ze średniego na wysoki",
    factDetail:
      "Reguła została dopasowana pierwszy raz. Nie utworzono duplikatu sprawy.",
    hypothesis: "Przyczyna nie została jeszcze zbadana",
    hypothesisDetail:
      "Analiza rozpocznie się automatycznie po zwolnieniu miejsca.",
    next: "Sprawa jest w kolejce. Powiadomienie i powiązane zadanie Linear zostały utworzone.",
  },
  {
    id: "HR-63",
    title: "Nieaktualny zespół w profilu pracownika",
    project: "HR",
    priority: "Wysoki",
    status: "done",
    label: "Komentarz w Jira",
    color: "green",
    age: "42 min",
    linear: "LIN-279",
    summary:
      "Analiza wskazuje na opóźnienie synchronizacji danych działu. <strong>Wynik i zalecenie weryfikacji następnego cyklu zostały przekazane w Jira.</strong>",
    fact: "Zmiana zespołu nastąpiła po ostatniej synchronizacji",
    factDetail:
      "Czasy aktualizacji w dołączonych danych potwierdzają kolejność zdarzeń.",
    hypothesis: "Potrzebne potwierdzenie po kolejnym cyklu",
    hypothesisDetail: "Nie stwierdzono podstaw do automatycznej zmiany kodu.",
    next: "Zweryfikować profil po następnej synchronizacji. Analiza zakończona; naprawa nie została uruchomiona.",
  },
];
const state = {
  concept: ["a", "b", "c"].includes(location.hash.slice(1))
    ? location.hash.slice(1)
    : "a",
  page: "home",
  view: "list",
  selected: "OPS-142",
  filter: "all",
  search: "",
  project: "all",
  tab: "analysis",
  enabled: true,
  interval: "5",
  priorities: ["Krytyczny", "Wysoki"],
  mail: true,
  sms: true,
  board: "Wsparcie / Portal klienta",
  saved: false,
};
const app = document.querySelector("#app");
const dialog = document.querySelector("#detail-dialog");
let toastTimer;
const concepts = {
  a: {
    title: "Centrum spraw",
    caption:
      "Kolejka + kontekst. Jedno miejsce, w którym oceniasz analizę i wybierasz następny krok.",
  },
  b: {
    title: "Przepływ pracy",
    caption:
      "Etapy + przepustowość. Widzisz, gdzie czeka praca, i otwierasz szczegóły wybranej sprawy.",
  },
  c: {
    title: "Briefing",
    caption:
      "Wyniki + priorytety. Zaczynasz od tego, co ustalono i co wymaga Twojej uwagi.",
  },
};
function toast(message) {
  const el = document.querySelector("#toast");
  el.textContent = message;
  el.classList.add("visible");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("visible"), 4200);
}
function badge(ticket) {
  return `<span class="badge ${ticket.color}">${ticket.label}</span>`;
}
function priority(ticket) {
  return `<span class="badge ${ticket.priority === "Krytyczny" ? "red" : "neutral"}">${ticket.priority === "Krytyczny" ? "!!" : "↑"} ${ticket.priority}</span>`;
}
function navigation() {
  const projects = ["Portal klienta", "Finanse", "HR"]
    .map(
      (name, index) => `
    <button class="nav-item project-nav ${["purple", "gold", "teal"][index]} ${state.project === name ? "active" : ""}"
      data-project="${name}" aria-pressed="${state.project === name}">
      <span class="project-dot" aria-hidden="true"></span>
      <span>${name}</span>
      <span class="project-count">${tickets.filter((t) => t.project === name).length}</span>
    </button>`,
    )
    .join("");
  return `<aside class="sidebar">
    <div class="brand"><span class="logo" aria-hidden="true"><i></i><i></i><i></i></span>harmony<span style="color:var(--muted);font-size:10px;margin-left:4px;font-weight:400">workspace</span></div>
    <div class="workspace"><span class="avatar">ET</span><span>Engineering Team</span><span class="muted" style="margin-left:auto">⌄</span></div>
    <nav aria-label="Główna">
      <button class="nav-item ${state.page === "home" ? "active" : ""}" data-page="home">${icon(state.concept === "b" ? "flow" : state.concept === "c" ? "grid" : "inbox")}${concepts[state.concept].title}<span class="count">2</span></button>
      <button class="nav-item ${state.page === "automation" ? "active" : ""}" data-page="automation">${icon("bolt")}Automatyzacje</button>
      <button class="nav-item ${state.page === "integrations" ? "active" : ""}" data-page="integrations">${icon("link")}Integracje</button>
    </nav>
    <div><div class="side-label">Projekty</div><nav aria-label="Projekty">
      ${projects}
      <button class="nav-item" data-project="all">${icon("grid")}Wszystkie projekty</button>
    </nav></div>
    <div class="side-bottom"><div class="connection"><span class="dot"></span>Jira i Linear · połączone</div><div class="user"><span class="avatar">DD</span><div>Daniel<small>Właściciel przestrzeni</small></div></div></div>
  </aside>`;
}
function shell(content) {
  return `<div class="shell">${navigation()}<div class="content"><header class="topbar"><div class="trail"><button class="mobile-menu" aria-label="Otwórz menu" aria-expanded="false" data-action="menu">${icon("menu")}</button><span>Przestrzeń zespołu</span><span>/</span><span>${state.page === "automation" ? "Automatyzacje" : state.page === "integrations" ? "Integracje" : concepts[state.concept].title}</span></div><div class="top-tools"><span class="live"><span class="dot"></span>Ostatnie sprawdzenie: 12:40</span><span class="tag">PODGLĄD</span></div></header><main id="main" class="page">${content}<footer class="page-foot"><span class="description">${concepts[state.concept].caption}</span><span class="shortcut">Prototyp · akcje są symulowane</span></footer></main></div></div>`;
}
function projectTickets() {
  return tickets.filter(
    (t) => state.project === "all" || t.project === state.project,
  );
}
function stats() {
  const rows = projectTickets();
  const count = (status) => rows.filter((t) => t.status === status).length;
  return `<div class="stats-line"><span><strong>${count("decision")}</strong> do Twojej decyzji</span><span><strong>${count("analysis")}</strong> analiza w toku</span><span><strong>${count("new")}</strong> w kolejce</span><span class="stat-last">${icon("clock")}${state.enabled ? "Kolejne sprawdzenie za " + escapeHtml(state.interval) + " min" : "Automatyzacja wstrzymana"}</span></div>`;
}
function viewSwitcher() {
  if (state.concept !== "a") return "";
  return `<div class="view-switch" role="group" aria-label="Widok spraw">
    <button data-view="list" aria-pressed="${state.view === "list"}">${icon("inbox")}Lista</button>
    <button data-view="kanban" aria-pressed="${state.view === "kanban"}">${icon("flow")}Kanban</button>
  </div>`;
}
function toolbar() {
  const rows = projectTickets();
  return `<div class="toolbar"><div class="filters" aria-label="Filtr spraw">${[
    ["all", "Wszystkie"],
    ["decision", "Do decyzji"],
    ["analysis", "W analizie"],
    ["done", "Zakończone"],
  ]
    .map(
      ([id, label]) =>
        `<button class="filter ${state.filter === id ? "active" : ""}" data-filter="${id}" aria-pressed="${state.filter === id}">${label}<span>${id === "all" ? rows.length : rows.filter((t) => t.status === id).length}</span></button>`,
    )
    .join(
      "",
    )}</div><label class="search">${icon("search")}<input id="search" type="search" aria-label="Szukaj spraw" placeholder="Szukaj sprawy…" value="${escapeHtml(state.search)}"></label>${viewSwitcher()}</div>`;
}
function visibleTickets() {
  const q = state.search.toLocaleLowerCase("pl");
  return tickets.filter(
    (t) =>
      (state.filter === "all" || state.filter === t.status) &&
      (state.project === "all" || state.project === t.project) &&
      `${t.id} ${t.title} ${t.project}`.toLocaleLowerCase("pl").includes(q),
  );
}
function ticketList(rows) {
  return rows.length
    ? rows
        .map(
          (t) =>
            `<button class="ticket ${state.selected === t.id ? "selected" : ""}" data-ticket="${t.id}" aria-pressed="${state.selected === t.id}"><div class="ticket-head"><span class="jira-icon" aria-hidden="true"></span><span class="mono muted">${t.id}</span>${priority(t)}<span class="age">${t.age}</span></div><h3>${t.title}</h3><div class="ticket-foot">${badge(t)}<span class="project">${t.project}</span></div></button>`,
        )
        .join("")
    : '<div class="empty">Nie ma spraw pasujących do filtrów.<br><button class="btn small" data-action="clear">Wyczyść filtry</button></div>';
}
function detail(ticket) {
  return `<article class="detail"><div class="detail-top"><span class="mono muted">${ticket.id}</span>${priority(ticket)}<span class="muted" style="margin-left:auto;font-size:10px">${ticket.project}</span></div><h2>${ticket.title}</h2><div class="detail-meta">${badge(ticket)}<span class="tag"><span class="jira-icon" aria-hidden="true"></span>${ticket.id}</span><span class="tag"><span class="linear-icon" aria-hidden="true"></span>${ticket.linear}</span><span class="tag">Tylko analiza</span></div><div class="detail-tabs" aria-label="Sekcja sprawy">${[
    ["analysis", "Analiza"],
    ["issue", "Zgłoszenie"],
    ["history", "Historia"],
  ]
    .map(
      ([id, label]) =>
        `<button class="detail-tab ${state.tab === id ? "active" : ""}" data-tab="${id}" aria-pressed="${state.tab === id}">${label}</button>`,
    )
    .join(
      "",
    )}</div>${state.tab === "analysis" ? analysis(ticket) : state.tab === "history" ? history(ticket) : issue(ticket)}<div class="detail-footer"><span class="sent">${icon("check")}${["decision", "done"].includes(ticket.status) ? "Analiza opublikowana w Jira" : "Zadanie utworzone w Linear"}</span><button class="btn small" data-action="open-jira" data-id="${ticket.id}">Zobacz w Jira ${icon("arrow")}</button><button class="btn small" data-action="open-linear" data-id="${ticket.linear}">Zobacz w Linear ${icon("arrow")}</button><button class="btn small primary" data-action="take" data-id="${ticket.id}">${icon("check")}Przyjmij sprawę</button></div></article>`;
}
function analysis(t) {
  return `<div class="analysis-label">${icon("spark")}${t.status === "analysis" ? "Agent analizuje zgłoszenie" : "Ustalenia agenta"}<span class="muted" style="margin-left:auto;font-size:10px;font-weight:400">${t.status === "analysis" ? "w toku" : "wersja 1"}</span></div><p class="analysis-summary">${t.summary}</p><div class="finding">${icon("check")}<div><b>${t.fact}</b><p>${t.factDetail}</p></div></div><div class="finding"><span class="uncertain">${icon("info")}</span><div><b>${t.hypothesis}</b><p>${t.hypothesisDetail}</p></div></div><div class="suggestion">${icon("arrow")}<div><h3>Następny krok</h3><p>${t.next}</p></div></div>`;
}
function history(t) {
  const done = ["decision", "done"].includes(t.status);
  return `<div class="event-line"><time>12:28</time><div>Wykryto dopasowanie reguły<small>${t.id === "OPS-145" ? "Priorytet został podniesiony do wysokiego." : "Zgłoszenie spełniło warunki tablicy i priorytetu."}</small></div></div><div class="event-line"><time>12:28</time><div>Utworzono ${t.linear} w Linear<small>Status początkowy: Todo · tryb pracy: analiza</small></div></div><div class="event-line"><time>12:28</time><div>Przekazano powiadomienia<small>E-mail: przyjęty do wysyłki · SMS: potwierdzone dostarczenie</small></div></div><div class="event-line"><time>${done ? "12:31" : "12:29"}</time><div>${done ? "Opublikowano analizę w Jira" : "Oczekiwanie na wynik analizy"}<small>${done ? "Zapisano identyfikator komentarza. Naprawa nie została uruchomiona." : "Szczegóły wykonania pojawią się w historii."}</small></div></div>`;
}
function issue(t) {
  return `<div class="issue-description"><p><span class="eyebrow">Opis zgłoszenia</span></p><p>${t.fact}. ${t.factDetail}</p><p><span class="eyebrow">Kontekst</span></p><p>Projekt: ${t.project}<br>Źródło: Jira · ${t.id}<br>Priorytet: ${t.priority}<br>Powiązane zadanie: ${t.linear}</p><div class="readonly-rule">${icon("shield")}Ta automatyzacja tworzy analizę i komentarz. Przygotowanie zmiany w kodzie wymaga osobnego uruchomienia.</div></div>`;
}
function heading(title, subtitle) {
  return `<div class="page-title"><div><h1>${title}</h1><p>${subtitle}</p></div><div class="page-actions"><button class="btn" data-page="automation">${icon("settings")}Reguły Jira</button><button class="btn primary" data-action="refresh">${icon("clock")}Sprawdź teraz</button></div></div>`;
}
function inbox() {
  const rows = visibleTickets();
  const selected = rows.find((t) => t.id === state.selected) || rows[0];
  if (selected) state.selected = selected.id;
  return `${heading(state.project === "all" ? "Centrum spraw" : state.project, "Wiesz, co się dzieje. Widzisz, co zrobić dalej.")}${stats()}${toolbar()}<div class="inbox"><section class="ticket-list" aria-label="Lista spraw"><div class="list-heading"><span>OSTATNIE ZGŁOSZENIA</span><span>${rows.length} spraw</span></div>${ticketList(rows)}</section>${selected ? detail(selected) : '<div class="empty">Zmień filtr, aby zobaczyć analizę.</div>'}</div>`;
}
function board() {
  const rows = visibleTickets();
  return `${heading(state.project === "all" ? concepts[state.concept].title : state.project, "Od zgłoszenia do ustaleń. Każda sprawa ma swój następny krok.")}${stats()}${toolbar()}<div class="board">${[
    ["new", "Wykryte", ""],
    ["analysis", "W analizie", "purple"],
    ["decision", "Do decyzji", "amber"],
    ["done", "Przekazane", "green"],
  ]
    .map(([id, label, color]) => {
      const group = rows.filter((t) => t.status === id);
      return `<section class="board-column" aria-label="${label}"><div class="column-title"><span class="column-dot ${color}"></span>${label}<span class="number">${group.length}</span></div>${group.map((t) => `<button class="board-card ${t.id === "OPS-142" ? "ready" : ""}" data-open="${t.id}"><div class="ticket-head"><span class="mono muted">${t.id}</span><span class="age">${t.age}</span></div>${priority(t)}<h3>${t.title}</h3><p>${t.status === "decision" ? t.hypothesis : t.status === "analysis" ? "Agent sprawdza dostępny kontekst i możliwe przyczyny." : t.status === "new" ? "Wykryto zmianę priorytetu. Zadanie Linear utworzone." : "Wynik analizy i następne kroki opublikowane w Jira."}</p>${t.status === "analysis" ? '<div class="progress" aria-hidden="true"><span></span></div>' : ""}<div class="ticket-foot"><span>${t.project}</span><span style="margin-left:auto">${icon(t.status === "done" ? "check" : "arrow")}</span></div></button>`).join("")}${group.length === 0 ? '<p class="column-hint">Brak spraw na tym etapie.</p>' : ""}</section>`;
    })
    .join(
      "",
    )}</div><div class="pipeline-note">${icon("bolt")}<div><b>Jira → analiza problemu</b><p>${state.enabled ? "Aktywna" : "Wstrzymana"} · co ${escapeHtml(state.interval)} min · ${state.priorities.join(" + ")} · naprawa uruchamiana osobno</p></div><button class="btn small" data-page="automation">Edytuj regułę ${icon("arrow")}</button></div>`;
}
function briefing() {
  const rows = tickets.filter(
    (t) => state.project === "all" || t.project === state.project,
  );
  const featured = rows.find((t) => t.status === "decision") || rows[0];
  return `<section class="brief-intro"><div class="brief-intro-top"><span class="eyebrow">Wtorek, 22 września · ${state.project === "all" ? "Twoje projekty" : state.project}</span><span class="badge green"><span class="dot"></span>Przegląd dnia</span></div><h1>Mniej doglądania.<br><em>Więcej jasności.</em></h1><p>Harmony sprawdza zgłoszenia i przygotowuje analizy.<br>Ty wybierasz następny krok tam, gdzie potrzebna jest decyzja.</p></section><div class="brief-layout"><section><div class="brief-section-title"><h2>Warto zająć się teraz</h2><span class="muted" style="font-size:10px">${rows.filter((t) => t.status === "decision").length} spraw do decyzji</span></div><article class="feature-story"><div class="ticket-head">${priority(featured)}<span class="mono muted">${featured.id}</span><span class="age">${featured.project}</span></div><h3>${featured.title}</h3><p>${featured.summary}</p><div class="story-result"><span class="dot"></span><span>${featured.label}</span><button class="btn primary small" data-open="${featured.id}">Przeczytaj analizę ${icon("arrow")}</button></div></article><div class="brief-list">${rows
    .filter((t) => t.id !== featured.id)
    .map(
      (t, i) =>
        `<button data-open="${t.id}"><span class="issue-number">0${i + 2}</span><div><h3>${t.title}</h3><small>${t.id} · ${t.project} · ${t.label}</small></div>${icon("arrow")}</button>`,
    )
    .join(
      "",
    )}</div></section><aside><section class="aside-section"><div class="brief-section-title"><h2>Obraz pracy</h2>${icon("grid")}</div><div class="mini-metrics"><div><strong>5</strong><small>wykrytych spraw</small></div><div><strong>3</strong><small>gotowe analizy</small></div><div><strong>2</strong><small>do decyzji</small></div></div></section><section class="aside-section"><h2 style="font-size:15px">Projekty</h2>${[
    ["Portal klienta", "1 analiza trwa", "purple"],
    ["Finanse", "Potrzebne dane", "amber"],
    ["HR", "Wynik przekazany", "green"],
  ]
    .map(
      ([p, label, color]) =>
        `<div class="project-health"><span class="project-dot"></span><div>${p}<small>Połączony z Jira i Linear</small></div><span class="badge ${color}">${label}</span></div>`,
    )
    .join(
      "",
    )}</section><section><div class="eyebrow">W tle</div><h3 style="margin-top:12px">Zgłoszenia pod kontrolą</h3><p class="muted" style="font-size:11px;line-height:1.9;margin:10px 0 13px">Sprawdzanie Jira co ${escapeHtml(state.interval)} min. Powiadomienia i analiza po pierwszym dopasowaniu priorytetu.</p><button class="btn small" data-page="automation">Ustaw automatyzację ${icon("arrow")}</button></section></aside></div>`;
}
function automation() {
  return `${heading("Reguła: pilne zgłoszenia", "Jira → powiadomienie → Linear → analiza → komentarz w Jira")}<form id="rule-form" class="automation-layout"><div class="config-card"><section class="config-section"><div class="section-heading"><span class="step-no">1</span><div><h3>Co i kiedy sprawdzać</h3><small>Wybierz źródło zgłoszeń i częstotliwość.</small></div><label class="enabled" style="margin-left:auto"><button type="button" class="switch" role="switch" aria-label="Reguła aktywna" aria-checked="${state.enabled}" data-action="toggle-rule"></button>${state.enabled ? "Aktywna" : "Wstrzymana"}</label></div><div class="fields"><label class="field">Połączenie<select name="connection"><option>Jira · Electrum</option></select></label><label class="field">Tablica<select name="board">${["Wsparcie / Portal klienta", "Finanse / Zgłoszenia", "HR / Wsparcie"].map((b) => `<option ${state.board === b ? "selected" : ""}>${b}</option>`).join("")}</select></label><label class="field">Sprawdzaj co<select name="interval">${["1", "5", "10", "15", "30", "60"].map((v) => `<option value="${v}" ${state.interval === v ? "selected" : ""}>${v} min</option>`).join("")}</select><small>Częstotliwość można zmienić niezależnie dla każdej reguły.</small></label><div class="field"><span>Priorytety</span><div class="priority-options">${["Krytyczny", "Wysoki", "Średni"].map((p) => `<label class="check-row"><input type="checkbox" name="priority" value="${p}" ${state.priorities.includes(p) ? "checked" : ""}>${p}</label>`).join("")}</div></div></div><div class="readonly-rule">${icon("check")}Uruchom analizę, gdy zgłoszenie pierwszy raz spełni warunki — także po podniesieniu priorytetu. Kolejne sprawdzenia nie powielają tej samej sprawy.</div></section><section class="config-section"><div class="section-heading"><span class="step-no">2</span><div><h3>Gdzie przekazać sprawę</h3><small>Powiązane zadanie pozwala śledzić dalszą pracę.</small></div></div><div class="fields"><label class="field">Projekt Linear<select name="linear-project"><option>Portal klienta</option><option>Finanse</option><option>HR</option></select></label><label class="field">Status początkowy<input value="Todo" readonly></label></div></section><section class="config-section"><div class="section-heading"><span class="step-no">3</span><div><h3>Powiadomienia i wynik</h3><small>Alert od razu, komentarz po zakończeniu analizy.</small></div></div><div class="fields"><label class="check-row"><input type="checkbox" name="mail" ${state.mail ? "checked" : ""}>E-mail do właściciela projektu</label><label class="check-row"><input type="checkbox" name="sms" ${state.sms ? "checked" : ""}>SMS do osoby dyżurującej</label></div><div class="readonly-rule">${icon("shield")}Tryb: tylko analiza. Agent publikuje ustalenia w Jira. Nie rozpoczyna przygotowania naprawy ani zmian w repozytorium.</div></section></div><aside class="config-side"><section class="rule-preview"><div class="eyebrow" style="margin-bottom:13px">Podgląd działania</div><h2>Twoja reguła, prostym językiem</h2><p id="rule-summary"></p><ul class="preview-steps"><li>${icon("bell")}<span id="notify-summary"></span></li><li>${icon("link")}Utwórz jedno powiązane zadanie Todo w Linear.</li><li>${icon("spark")}Przeanalizuj problem w kontekście projektu.</li><li>${icon("check")}Opublikuj wynik jako komentarz w Jira.</li></ul><button class="btn" type="button" data-action="simulate">${icon("flow")}Przetestuj na przykładzie</button><button class="btn primary" type="submit">${icon("check")}Zapisz regułę w podglądzie</button><div id="simulation" hidden></div></section><p class="config-note">To interaktywna makieta. Zmiany pozostają w tym podglądzie do odświeżenia strony. Żadne zgłoszenia, wiadomości ani komentarze nie są wysyłane.</p></aside></form>`;
}
function integrations() {
  return `${heading("Integracje", "Połączenia, na których opiera się Twoja automatyzacja.")}<div class="integration-grid">${[
    [
      "Jira",
      "Źródło zgłoszeń",
      "Odczyt tablic i priorytetów, publikacja wyników analizy.",
      "grid",
    ],
    [
      "Linear",
      "Koordynacja pracy",
      "Powiązane zadania i osobne uruchamianie napraw.",
      "flow",
    ],
    [
      "E-mail",
      "Powiadomienia zespołu",
      "Alerty o wykrytych zgłoszeniach i wynikach analizy.",
      "mail",
    ],
    [
      "SMS",
      "Powiadomienia dyżurnego",
      "Pilne zgłoszenia przekazywane na skonfigurowany numer.",
      "phone",
    ],
  ]
    .map(
      ([name, label, desc, i]) =>
        `<section class="integration-card"><span class="badge green">Połączono · przykład</span><span class="integration-icon">${icon(i)}</span><h2>${name}</h2><p><b>${label}</b><br>${desc}</p><button class="btn small" data-action="check-connection" data-id="${name}">Sprawdź połączenie ${icon("arrow")}</button></section>`,
    )
    .join("")}</div>`;
}
function updateRule() {
  const summary = document.querySelector("#rule-summary");
  if (!summary) return;
  summary.innerHTML = `Co <strong>${escapeHtml(state.interval)} min</strong> sprawdzaj tablicę <strong>${escapeHtml(state.board)}</strong>. Gdy zgłoszenie pierwszy raz otrzyma priorytet <strong>${state.priorities.length ? state.priorities.map(escapeHtml).join(" lub ") : "— wybierz priorytet"}</strong>, rozpocznij analizę.`;
  document.querySelector("#notify-summary").textContent =
    state.mail && state.sms
      ? "Wyślij e-mail i SMS."
      : state.mail
        ? "Wyślij e-mail."
        : state.sms
          ? "Wyślij SMS."
          : "Powiadomienia wyłączone.";
}
function render() {
  document.body.dataset.concept = state.concept;
  document
    .querySelectorAll(".concept-switch button")
    .forEach((b) =>
      b.setAttribute(
        "aria-pressed",
        String(b.dataset.concept === state.concept),
      ),
    );
  document.title = `Harmony — ${concepts[state.concept].title} · propozycja ${state.concept.toUpperCase()}`;
  app.innerHTML = shell(
    state.page === "automation"
      ? automation()
      : state.page === "integrations"
        ? integrations()
        : state.concept === "a"
          ? state.view === "kanban"
            ? board()
            : inbox()
          : state.concept === "b"
            ? board()
            : briefing(),
  );
  updateRule();
}
function openDetail(id) {
  state.selected = id;
  state.tab = "analysis";
  const t = tickets.find((t) => t.id === id);
  dialog.innerHTML = `<div class="dialog-bar"><span>Szczegóły sprawy · ${t.project}</span><button data-action="close" aria-label="Zamknij szczegóły">${icon("close")}</button></div>${detail(t)}`;
  dialog.showModal();
}
document.addEventListener("click", (event) => {
  const b = event.target.closest("button");
  if (!b) return;
  if (b.dataset.concept) {
    state.concept = b.dataset.concept;
    location.hash = state.concept;
    state.filter = "all";
    state.search = "";
    render();
    return;
  }
  if (b.dataset.page) {
    state.page = b.dataset.page;
    render();
    window.scrollTo(0, 0);
    return;
  }
  if (b.dataset.project) {
    state.project = b.dataset.project;
    state.page = "home";
    state.filter = "all";
    state.search = "";
    render();
    return;
  }
  if (b.dataset.filter) {
    state.filter = b.dataset.filter;
    render();
    return;
  }
  if (b.dataset.view) {
    state.view = b.dataset.view;
    render();
    document.querySelector(`[data-view="${state.view}"]`).focus();
    return;
  }
  if (b.dataset.ticket) {
    state.selected = b.dataset.ticket;
    state.tab = "analysis";
    if (innerWidth <= 600) openDetail(state.selected);
    else render();
    return;
  }
  if (b.dataset.open) {
    openDetail(b.dataset.open);
    return;
  }
  if (b.dataset.tab) {
    state.tab = b.dataset.tab;
    if (dialog.open) {
      dialog.querySelector(".detail").outerHTML = detail(
        tickets.find((t) => t.id === state.selected),
      );
      dialog.querySelector(`[data-tab="${state.tab}"]`).focus();
    } else {
      render();
      document.querySelector(`[data-tab="${state.tab}"]`).focus();
    }
    return;
  }
  switch (b.dataset.action) {
    case "menu": {
      const sidebar = document.querySelector(".sidebar");
      sidebar.classList.toggle("open");
      b.setAttribute(
        "aria-expanded",
        String(sidebar.classList.contains("open")),
      );
      break;
    }
    case "close":
      dialog.close();
      break;
    case "clear":
      state.filter = "all";
      state.search = "";
      state.project = "all";
      render();
      break;
    case "refresh":
      toast(
        "Przykładowe sprawdzenie: brak nowych dopasowań. Istniejące sprawy nie zostały powielone.",
      );
      break;
    case "open-jira":
      toast(
        `W gotowej aplikacji otworzy się zgłoszenie ${b.dataset.id} w Jira.`,
      );
      break;
    case "open-linear":
      toast(
        `W gotowej aplikacji otworzy się zadanie ${b.dataset.id} w Linear.`,
      );
      break;
    case "take":
      b.innerHTML = `${icon("check")}Przyjęta przez Ciebie`;
      b.disabled = true;
      toast(
        "Symulacja: sprawa przyjęta. Przygotowanie naprawy nie zostało uruchomione.",
      );
      break;
    case "toggle-rule":
      state.enabled = !state.enabled;
      b.setAttribute("aria-checked", String(state.enabled));
      b.parentElement.lastChild.textContent = state.enabled
        ? "Aktywna"
        : "Wstrzymana";
      break;
    case "simulate": {
      const box = document.querySelector("#simulation");
      box.hidden = false;
      box.className = "simulation";
      box.innerHTML = state.priorities.length
        ? `<b>Przykład: ${escapeHtml(state.priorities[0])}, nowe dopasowanie</b>${state.enabled ? "✓ Sprawa zostanie zarejestrowana.<br>✓ Analiza uruchomi się jeden raz.<br>✓ Ponowne sprawdzenie nie utworzy duplikatu." : "Reguła jest wstrzymana. Żadna akcja nie zostanie wykonana."}`
        : "Wybierz przynajmniej jeden priorytet.";
      break;
    }
    case "check-connection":
      toast(
        `Symulacja: ${b.dataset.id} odpowiada poprawnie. Nie wykonano rzeczywistego połączenia.`,
      );
      break;
  }
});
document.addEventListener("input", (event) => {
  if (event.target.id === "search") {
    const input = event.target;
    const start = input.selectionStart;
    state.search = input.value;
    render();
    const next = document.querySelector("#search");
    next.focus();
    if (next.type !== "search" && start !== null)
      next.setSelectionRange(start, start);
  }
});
document.addEventListener("change", (event) => {
  if (!event.target.closest("#rule-form")) return;
  const form = document.querySelector("#rule-form");
  state.interval = form.elements.interval.value;
  state.board = form.elements.board.value;
  state.priorities = [...form.querySelectorAll("[name=priority]:checked")].map(
    (el) => el.value,
  );
  state.mail = form.elements.mail.checked;
  state.sms = form.elements.sms.checked;
  state.saved = false;
  document.querySelector("#simulation").hidden = true;
  updateRule();
});
document.addEventListener("submit", (event) => {
  if (event.target.id !== "rule-form") return;
  event.preventDefault();
  if (!state.priorities.length) {
    toast("Wybierz przynajmniej jeden priorytet.");
    event.target.querySelector("[name=priority]").focus();
    return;
  }
  state.saved = true;
  toast(
    `Zapisano w podglądzie: ${state.enabled ? "sprawdzanie co " + state.interval + " min" : "reguła wstrzymana"}. Bez połączeń z zewnętrznymi systemami.`,
  );
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    const menu = document.querySelector(".sidebar.open");
    if (menu) {
      menu.classList.remove("open");
      const trigger = document.querySelector("[data-action=menu]");
      trigger.setAttribute("aria-expanded", "false");
      trigger.focus();
    }
  }
});
window.addEventListener("hashchange", () => {
  const next = location.hash.slice(1);
  if (["a", "b", "c"].includes(next) && next !== state.concept) {
    state.concept = next;
    render();
  }
});
render();
