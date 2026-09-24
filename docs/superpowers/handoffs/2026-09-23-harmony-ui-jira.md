---
title: "Harmony UI/Jira — przekazanie do nowej sesji"
date: 2026-09-24
status: m5-ready-for-review
audience: coding-agent
---

# Harmony UI/Jira — przekazanie do nowej sesji

## Cel i źródła

Wdrażamy zaakceptowany wariant A Centrum spraw (Lista/Kanban) oraz przepływ Jira Cloud → alert SMTP/SMSAPI → Linear Todo → analiza tylko do odczytu → komentarz Jira. Automatyczna naprawa i produkcyjna aktywacja reguł nie należą do tego etapu.

- [Plan i kontrakt wykonania](../plans/2026-09-22-harmony-ui-jira.md), szczególnie §1 oraz T20–T29.
- [Specyfikacja](../specs/2026-09-22-harmony-ui-jira-design.md).
- Zaakceptowana [interaktywna makieta A](../../mockups/index.html), z [CSS](../../mockups/styles.css) i [JS](../../mockups/app.js).
- Lokalne, nieśledzone zrzuty makiety: `/home/ddziag/projects/Harmony/output/t00-preflight/` i `output/playwright/`.
- Instrukcje repo: `elixir/AGENTS.md`.

Plan ma siedem milestone’ów: M0–M6. Każde Txx jest osobnym zleceniem dla agenta implementującego; koordynator powtarza bramki, recenzuje diff i commituje. Pełne testy aplikacji (`make all`) uruchamia się na końcu milestone’u. Nie wykonywać testów z realnym mailem/SMS, zapisów do produkcyjnych Jira/Linear ani płatnej analizy.

## Stan zweryfikowany 24 września 2026

| Etap | Stan |
| --- | --- |
| M0–M3 | Scalone do `main` (PR #17–#20), `origin/main` = `db2d0d1`. |
| M4 | Ukończony; Draft PR [#21](https://github.com/dezet/Harmony/pull/21) (`feature/harmony-ui-jira-m4`) do scalenia przez użytkownika. |
| M5 | Ukończony na `feature/harmony-ui-jira-m5` (stos nad M4); Draft PR do scalenia po M4. |
| M6 | Nie rozpoczęto. |

Bramka M4 (log: `output/verification/m4/`, lokalny, nieśledzony): `make all` exit 0 — 1041 testów, pokrycie 85,28%, Dialyzer 0 błędów; frontend 293 testy.

Bramka M5 (`output/verification/m5/`): `make all` exit 0 — Credo bez uwag, 1064 testy, 0 błędów, pokrycie 85,35%, Dialyzer 0 błędów; frontend Vitest 481 testów, typecheck, lint i build exit 0.

## Co zawiera M4

- T15 SMTP (Swoosh + gen_smtp, TLS verify peer, timeout po DATA = unknown) i bezpieczny szablon maila.
- T16 SMSAPI (idx/check_idx, kod 53 = już przyjęte, 134 jednostki UTF-16), kanały e-mail/SMS w Dispatcherze.
- T16b (luka planu, spec §6.2/§10.1): proces `Intake.DispatcherRuntime` (tick 1 s, 4 I/O + 1 analiza), numery SMS w regułach w E.164; Outbox nie claimuje analizy przy wyłączonych efektach (§13).
- T17 operatorskie API `/api/v1` z CSRF/Origin/JSON na nowych mutacjach; test-send przez Outbox z `Idempotency-Key`.
- T17b (luka planu, spec §7.1/§11.2): warunki aktywacji reguły (Jira, Linear Todo i etykieta, profil analizy, kanały) oraz `scan_id` ręcznego sprawdzenia.
- T18 projekcja spraw w PostgreSQL (lista, szczegół, historia, stałe cursory, `actions` z backendu); T18b ranking priorytetów Jira zapisany przy aktywacji i indeksy projekcji.
- T19 kanał `intake:workspace` z emisją po commit oraz hooki React Query spraw.
- Stabilizacja testów: Orchestrator zachowuje ostatnią poprawną konfigurację przy błędnym `WORKFLOW.md`, `WorkflowStore` bez wyścigu odczytu, testy odizolowane od globalnego Orchestratora.

## Co zawiera M5

- T20 tokeny i typografia A, shell desktop/mobile po polsku (menu mobilne na dialogu Base UI — rejestr shadcn `sheet` importuje podejrzany pakiet npm `cn`), `display_name`/`ui_color` projektu w DB/API/YAML/formularzu.
- T21 Centrum spraw: lista, filtry i wyszukiwanie w URL, liczniki z agregatów, „Sprawdź teraz” bez fałszywego sukcesu.
- T22 szczegół sprawy: zakładki, analiza bez raw HTML, przyjęcie i zatwierdzenie naprawy jako osobne mutacje, reanaliza z ostrzeżeniem o koszcie, retry pojedynczej delivery.
- T23 Kanban: cztery kolumny ze stronicowaniem per kolumna, bez DnD.
- T24 automatyzacje: lista, formularz A, pickery Jira/Linear, podgląd zapisanej wersji, aktywacja z potwierdzeniem, konflikt wersji.
- T25 integracje: sekrety tylko do zapisu, test połączenia bez wysyłki, test-send z `Idempotency-Key`; T25b allowlista hostów SMTP w API i reset stanu testu po zmianie ustawień/sekretu.

## Otwarte punkty

- Kody błędów SMSAPI i format pola `to` potwierdzić w G-LIVE (T29).
- Inne ścieżki Orchestratora (`:snapshot`, pobieranie z Linear, rekoncyliacja przy działających zadaniach) nadal padają na błędnym `WORKFLOW.md` — sprzeczne z SPEC §6.2, poza zakresem tego planu; decyzja użytkownika.
- `analysis.max_concurrent` w Config nie jest czytane (pula analizy = 1, spec §6.2).
- Sprawy z reguł aktywowanych przed migracją rankingu mają tone `normal` do ponownej aktywacji.
- `ObservabilityChannel` i `RunChannel` prawdopodobnie dostają podwójne pushe (jawna subskrypcja tego samego topicu) — istniejące zachowanie, niezmienione.
- Niestabilny, istniejący test `OrchestratorStatusTest` (orchestrator_status_test.exs:1462) — sporadyczny wyścig.
- Ostrzeżenie o niezapisanym formularzu reguły nie przechwytuje nawigacji z sidebaru/okruszków — wymaga data routera (`createBrowserRouter`), zmiana architektury do decyzji użytkownika.
- UI rozpoznaje odmowę aktywacji (422) heurystycznie; rozważyć stały kod `activation_blocked` w backendzie.
- E2E `e2e/react-spa.spec.ts` oczekuje starego shellu — do aktualizacji w T27.
- Baza dev wymaga `mix ecto.migrate` (priority_ranking, indeksy projekcji, display_name).
- Wszystkie worktree współdzielą bazę `harmony_test`; nie uruchamiać równolegle pełnych zestawów z dwóch worktree.

## Następny krok

M6 (T26–T29, regresja, E2E, dokumentacja, końcowe bramki) na gałęzi `feature/harmony-ui-jira-m6` nad M5. Worktree roboczy: `/home/ddziag/projects/Harmony-m4` (nazwa historyczna). G-LIVE (T29.3) i produkcyjne `enabled=true` wymagają zgody operatora. Testowy `CLOAK_KEY` musi być 32-bajtowym kluczem w Base64, np. `python3 -c 'import base64; print(base64.b64encode(b"k" * 32).decode())'`.
