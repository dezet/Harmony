---
title: "Harmony — plan wdrożenia UI A i automatyzacji Jira"
date: 2026-09-22
status: awaiting-approval
audience: implementation-agent
baseline_commit: ba3ae25d191a4ca771242ae3be54b4fcb071d646
specification: ../specs/2026-09-22-harmony-ui-jira-design.md
---

# Harmony — plan wdrożenia UI A i automatyzacji Jira

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

## 1. Kontrakt wykonania

Cel: dostarczyć zaakceptowane Centrum spraw A oraz Jira Cloud → alert SMTP/SMSAPI →
Linear Todo → analiza tylko do odczytu → komentarz Jira, bez automatycznej naprawy.
Źródło wymagań: [specyfikacja](../specs/2026-09-22-harmony-ui-jira-design.md).
Stack: obecny Elixir/Phoenix/Ecto/PostgreSQL i React/TypeScript/Query/Base UI/Tailwind.

Plan jest przeznaczony do pracy zadanie po zadaniu. Nie uruchamiać całego planu
w jednym poleceniu do modelu. Każde Txx jest osobnym zleceniem, a zależności i bramki
muszą być spełnione przed jego rozpoczęciem. Pierwsze zlecenie obejmuje wyłącznie T00.
Jeśli skille wskazane w nagłówku nie są dostępne, wykonywać kroki sekwencyjnie
według tego dokumentu; nie instalować ich ani nie uruchamiać dodatkowych agentów samodzielnie.

### 1.1. Reguły dla modelu wykonawczego

- Przeczytaj wskazane paragrafy specyfikacji, pliki wejściowe i instrukcje repo.
- Najpierw napisz test wykazujący brak zachowania, uruchom i zachowaj wynik RED.
  Następnie minimalna implementacja, wynik GREEN i lokalny przegląd zmian.
- Nie zmieniaj testu po to, aby osłabić kryterium. Nie używaj skip/todo do obchodzenia bramki.
- Edytuj tylko pliki zadania i bezpośrednio wymagane testy/importy; rozszerzenie zgłoś.
- Nie zmieniaj nazw stanów, kontraktów, kolejności kolumn, wyglądu, dostawców ani architektury.
- Brak danych/poświadczeń → jawny błąd lub zablokowany test live, nigdy mock w produkcji.
- Żadnych zewnętrznych zapisów w Jira/Linear, realnych SMS/maili ani płatnych analiz
  podczas testów automatycznych. Wstrzykuj adaptery, zegar, UUID i transport.
- Nie modyfikuj `components/ui/*` ręcznie. Korzystaj z obecnych prymitywów;
  brakujące dialog/sheet dodaj przez shadcn z aktualnym `components.json` i lockfile.
- Nie zmieniaj worktree ani gałęzi użytkownika bez potrzeby. Nie używaj `git add -A`.
- Publiczne `def` w Elixir mają `@spec`; błędy domenowe nie trafiają do UI jako stacktrace.
- Nigdy nie kasuj bazy, wolumenów ani ticketów jako części weryfikacji.
- Bez automatycznych merge, push do main ani przechodzenia do następnego milestone
  przed zaakceptowaniem raportu poprzedniego przez koordynatora.

### 1.2. Kiedy zatrzymać zadanie

Zatrzymaj zależny etap, zachowaj zmiany i przekaż dowód, gdy:

1. Nie da się wymusić izolacji analizatora opisanej w spec §9.
2. Linear nie obsługuje UUID create/Todo/etykiety wymaganych przez spec.
3. Istniejący kod wymaga zmiany semantyki stop/retry/dispatch poza spec.
4. Test bazowy nie przechodzi przed zmianą i dotyczy obszaru zadania.
5. Występuje konflikt między dokumentem, makietą i instrukcjami repo.
6. Brakuje zewnętrznej zgody do manualnego gate albo dostępu do testowej instancji.

Nie wybieraj alternatywnego rozwiązania „na własną rękę”. Raport blokera:
warunek, polecenie, kod wyjścia, fragment błędu bez sekretów, wymagane rozstrzygnięcie.
Inne zadania wolno rozpocząć tylko po decyzji koordynatora i bez łamania zależności.

### 1.3. Format raportu pojedynczego zadania

```text
Zadanie: Txx
Worktree: pełna ścieżka
Gałąź: nazwa
PR: URL albo „nie utworzono — powód”
Zmodyfikowane pliki: lista
RED: dosłowna komenda, kod wyjścia, istotne surowe wyjście
GREEN: dosłowna komenda, kod wyjścia, istotne surowe wyjście
Kryteria AC: identyfikatory i dowody
Otwarte punkty: lista albo „brak”
Nie wykonywano: testy live / wysyłki / inne pominięte bramki
```

Raport „testy przechodzą” bez komend i kodów jest nieprzyjęty. Koordynator sam
powtarza sprawdzenia. Zielony unit test nie zastępuje testu współbieżności w PostgreSQL.

## 2. Etapy i zależności

| Milestone                | Zadania w kolejności | Wynik / granica                                                          |
| ------------------------ | -------------------- | ------------------------------------------------------------------------ |
| M0 — baza                | T00–T01              | Utrwalone wzorce i fixture kontraktów; nic nie wysyła danych             |
| M1 — dane i ochrona      | T02–T06              | Schemat, reguły, outbox i guard; import nadal wyłączony                  |
| M2 — Jira i Linear       | T07–T10              | Deterministyczny intake z testami restartów; zero produkcyjnej aktywacji |
| M3 — analiza             | T11–T14              | Read-only runner, wynik, komentarz, ręczna zgoda; gate izolacji          |
| M4 — powiadomienia i API | T15–T19              | SMTP/SMSAPI, REST, projekcja, realtime                                   |
| M5 — interfejs A         | T20–T25              | Shell, lista, Kanban, szczegół, reguły i integracje                      |
| M6 — zgodność i wydanie  | T26–T29              | Stare funkcje zachowane, E2E, dokumentacja, końcowe bramki               |

Nie wdrażać M2 bez guard z M1. Produkcyjne reguły pozostają disabled do końca T29.
Każdy milestone ma osobną gałąź i Draft PR, ze wskazaniem zależności od poprzedniego;
po jego scaleniu następny opierać na rzeczywistym aktualnym main, nie starym origin.
To GitHub: użyć PR, nie identyfikatorów projektów GitLab. Nie tworzyć zgłoszeń Linear
ani zmieniać ich statusów, dopóki użytkownik nie wskaże właściwego ticketu.

### 2.1. Polecenia i środowisko

Wszystkie ścieżki w zadaniach są względem repo root, chyba że podano skrót:

- `BE` = `elixir/lib/symphony_elixir/`.
- `WEB` = `elixir/lib/symphony_elixir_web/`.
- `BT` = `elixir/test/symphony_elixir/`.
- `FE` = `elixir/assets/src/`.
- `FIX` = `elixir/assets/src/test/fixtures/`.

Polecenia podane w każdym zadaniu uruchamiać z repo root. `mise exec -- mix` wymaga
zainstalowanych wersji z konfiguracji projektu. PostgreSQL testowy ma istniejące
zmienne `HARMONY_DATABASE_*`, nie tworzyć nowej konwencji portów.
Do uruchomienia środowiska służy obecne `elixir/dev/harmony.sh`; nie używać `reset`.
`CLOAK_KEY` wymagany nawet w testach; korzystać z testowego sekretu, nie produkcyjnego.
Nie wypisywać wartości klucza. Weryfikacja dokumentów używa `.markdownlint-cli2.jsonc`.
Konfiguracja lint jest zgodna z sąsiednim projektem w zakresie długich linii/tabel:
`../portfel-projektow/.markdownlint-cli2.jsonc:6` i `:14`; nie wymaga tego checkoutu do działania.

## 3. M0 — wzorce i kontrakty

### T00. Preflight i zabezpieczenie wzorca

Wejście: cała specyfikacja, `docs/mockups/*`, `elixir/AGENTS.md`,
`elixir/assets/{AGENTS,CLAUDE}.md`, `elixir/Makefile`, `elixir/assets/package.json`.
Zależność: zatwierdzenie obu dokumentów przez użytkownika.

- [ ] T00.1 Sprawdź `git status --short`, `git branch --show-current`, `git ls-remote origin refs/heads/main`.
- [ ] T00.2 Zachowaj niezwiązane zmiany. Zapisz baseline SHA i ścieżkę worktree w raporcie.
- [ ] T00.3 Uruchom istniejące testy frontend/backend obszaru layout, API, core i storage.
- [ ] T00.4 Uruchom makietę A lokalnie i obejrzyj Lista/Kanban, szczegół, regułę, menu projektów.
- [ ] T00.5 Zachowaj lokalne screenshots 1440×1050 i 390×844; nie kopiuj ich zamiast komponentów.
- [ ] T00.6 Sprawdź wersję i lokalny schema/help CLI agenta bez uruchamiania płatnej analizy.

Komendy bazowe:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/storage_test.exs
cd assets
npm run test -- --run src/components/layout src/lib/api.test.ts
npm run typecheck
```

Odbiór: brak zmian produkcyjnych; znane wyniki bazowe i dostępny wzorzec.
Nie stosuje się RED do odczytu i diagnostyki. Błędy bazowe zgłosić, nie maskować.

### T01. Fixture kontraktów i mapa stanów

Spec: §3, §6, §11, §14. Zależność: T00.
Pliki: nowe `FIX/cases_page.fixture.json`, `case_detail.fixture.json`,
`automation_rule.fixture.json`, `integration_connection.fixture.json`;
`FE/types/contract.ts`, `FE/types/contract.test.ts`; nowy `BT/intake_contract_test.exs`.

- [ ] T01.1 RED: fixture wymaga obu linków, actions, statusu publikacji i mode analysis_only.
- [ ] T01.2 Zdefiniuj typy dokładnie według spec, w tym null zamiast brakujących pól.
- [ ] T01.3 Fixture pięciu spraw z makiety: OPS-142, OPS-139, FIN-87, OPS-145, HR-63;
      ID syntetyczne, domeny example.atlassian.net/example Linear, żadnych realnych odbiorców.
- [ ] T01.4 Dodaj fixture legacy implementation, ci_fix, code_review i address_review.
- [ ] T01.5 Spisz rzeczywiste statusy z storage/presenter/orchestratora jako przypadki
      testu mapowania; nieznany status musi pozostać widoczny jako attention.
- [ ] T01.6 BE i FE czytają te same fixture; brak duplikowania ręcznie innego kontraktu.

Test: `cd elixir/assets && npm run test -- --run src/types/contract.test.ts`;
`cd elixir && mise exec -- mix test test/symphony_elixir/intake_contract_test.exs`.
Odbiór: AC04/AC16, kontrakt zamrożony bez placeholderów i bez połączeń zewnętrznych.

## 4. M1 — dane, kolejka i ochrona implementacji

### T02. Schemat PostgreSQL i migracje

Spec: §6, §13. Zależność: T01.
Pliki: nowe migracje `elixir/priv/repo/migrations/20260922010000_create_intake.exs`,
`20260922010100_add_project_presentation.exs`; nowe moduły BE `storage/`:
`integration_connection.ex`, `automation_rule.ex`, `automation_scan.ex`,
`jira_observation.ex`, `intake_case.ex`, `intake_analysis.ex`,
`integration_delivery.ex`, `intake_event.ex`; nowy `BT/intake_storage_test.exs`.

- [ ] T02.1 RED: zduplikowany case/Linear UUID/analysis version/delivery key odrzucony przez DB.
- [ ] T02.2 Utwórz pola, FK, CHECK i indeksy spec; wszystkie nullability zgodnie z `?`.
- [ ] T02.3 Sprawdź dwa jednoczesne inserty tego samego Jira ID: tylko jeden zwycięzca.
- [ ] T02.4 Zweryfikuj roundtrip szyfrowania i brak jawnego tokenu w surowej kolumnie DB.
- [ ] T02.5 Migracja istniejącego projektu zachowuje sekret/config/WorkRun i nadaje ui_color purple.
- [ ] T02.6 Przetestuj up/down/up wyłącznie na osobnej pustej testowej bazie.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_storage_test.exs`.
Odbiór: AC08/AC14/AC16; nie włączać schedulera.

### T03. Kontekst konfiguracji i walidacja reguł

Spec: §6.1, §7.1, §10, §13. Zależność: T02.
Pliki: nowe `BE/intake.ex`, `BE/intake/connections.ex`, `BE/intake/rules.ex`;
`BE/config.ex`, `BE/config/schema.ex`; nowe `BT/intake_config_test.exs`, `BT/intake_rules_test.exs`.

- [ ] T03.1 RED: interwały 59/86401, puste priority IDs, obcy connection kind i pusty odbiorca → błąd.
- [ ] T03.2 Wprowadź runtime intake/analysis config z wyłączonymi domyślnymi flagami.
- [ ] T03.3 Reguła snapshotuje cel i odbiorców; PATCH wersjonowany, zmiana źródła wyłącza regułę.
- [ ] T03.4 Zamknij niezmienne pola po aktywacji oraz zmianę site_url po wykorzystaniu.
- [ ] T03.5 Secret blank zachowuje, clear usuwa, JSON/presenter pokazuje tylko set/unset.
- [ ] T03.6 Aktywne nakładające się źródło odrzucone; disable nie usuwa case ani ochrony.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_config_test.exs test/symphony_elixir/intake_rules_test.exs`.
Odbiór: AC05/AC14/AC19. Nie dodawać drugiego źródła konfiguracji w env poza Config.

### T04. Outbox i leasing efektów

Spec: §6.2, §10.4. Zależność: T03.
Pliki: nowe `BE/intake/outbox.ex`, `BE/intake/dispatcher.ex`,
`BT/intake_outbox_test.exs`, `BT/intake_dispatcher_test.exs`.

- [ ] T04.1 RED: dwa procesy claimują ten sam delivery, tylko jeden otrzymuje lease.
- [ ] T04.2 Zaimplementuj SKIP LOCKED, heartbeat i CAS na lease_token, bez HTTP w transakcji.
- [ ] T04.3 Wstrzyknij zegar/jitter, przetestuj wszystkie cztery odstępy i Retry-After.
- [ ] T04.4 Po crash/lease expiry efekt z możliwością zapisu → unknown; analiza ma osobny recovery.
- [ ] T04.5 Manual retry, paused/enable, limit per connection i wyczerpanie prób nie gubią historii.
- [ ] T04.6 Kill switch blokuje nowe claimy, a rezultat już trwającego requestu może być zapisany.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_outbox_test.exs test/symphony_elixir/intake_dispatcher_test.exs`.
Odbiór: AC08/AC13/AC19; testy współbieżności na realnym PostgreSQL, nie ETS.

### T05. ExecutionGate przed każdą implementacją

Spec: §8.2. Zależność: T02–T04.
Pliki: nowe `BE/intake/execution_gate.ex`, `BT/intake_execution_gate_test.exs`;
`BE/work_sources/linear_issue_source.ex`, `BE/orchestrator.ex`, `BE/agent_runner.ex`;
regresje w `BT/core_test.exs`, `BT/orchestrator_actions_test.exs`.

- [ ] T05.1 RED: zaimportowane Todo uruchamia runnera w obecnym kodzie; nowy test ma to wykazać.
- [ ] T05.2 Dodaj guard na etapie kandydatów i finalnym dispatch, także retry/continuation.
- [ ] T05.3 Case z rezerwowanym UUID, brak zgody → zero startów workspace i runnera.
- [ ] T05.4 Usunięta etykieta, brak mapowania z markerem, DB down, obcy project_id → odmowa.
- [ ] T05.5 Zwykły niezarządzany Todo nadal przechodzi dotychczasowe warunki.
- [ ] T05.6 Restart orchestratora i intake.enabled=false nie wyłączają gate.
- [ ] T05.7 Zgoda nie omija aktywnego statusu, assignee, capacity, blockerów ani repo policy.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_execution_gate_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_actions_test.exs`.
Odbiór: AC09/AC15/AC19. To obowiązkowa bramka przed jakimkolwiek create Linear.

### T06. Poprawne poświadczenia i zakres projektu Linear

Spec: §8.1–8.2. Zależność: T05.
Pliki: `BE/linear/client.ex`, `BE/work_sources/linear_issue_source.ex`, `BE/orchestrator.ex`;
nowy `BT/linear_project_scope_test.exs`.

- [ ] T06.1 RED: dwa projekty, dwa tokeny, różne listy issue; żaden nie dostaje cudzych zadań.
- [ ] T06.2 Dodaj jawne opcje project/token do client/source, zachowaj dotychczasowe arności.
- [ ] T06.3 Per-project fetcher przekazuje poświadczenia projektu zamiast globalnego fetchera.
- [ ] T06.4 Stan issue w retry/revalidation również pobierany we właściwym zakresie.
- [ ] T06.5 200+GraphQL errors nie jest sukcesem; transport nie loguje tokenu ani opisu.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/linear_project_scope_test.exs test/symphony_elixir/core_test.exs`.
Odbiór M1: AC09/AC14/AC16, targeted testy T02–T06 oraz `mix format --check-formatted` i `mix specs.check` (przez mise).

## 5. M2 — odczyt Jira i bezpieczne kopiowanie

### T07. Jira Cloud transport, pickery i ADF

Spec: §7.2, §9.3, §12. Zależność: M1.
Pliki: nowe `BE/jira/cloud_client.ex`, `BE/jira/adf.ex`, `BE/jira/issue.ex`;
nowe `BT/jira_cloud_client_test.exs`, `BT/jira_adf_test.exs`.

- [ ] T07.1 RED: dwa token-page wyniki muszą dać wszystkie issue; 200 malformed → jawny błąd.
- [ ] T07.2 Implementuj classic/scoped auth, board→filter i /search/jql, bez starego /search.
- [ ] T07.3 Implementuj odczyt boards/filters/priorities i komentarzy z pełną paginacją.
- [ ] T07.4 Obsłuż 401/403/404/429/5xx, Retry-After i timeout bez logowania body.
- [ ] T07.5 URL evil.atlassian.net.example.com, userinfo, redirect z auth → odrzucenie.
- [ ] T07.6 ADF: akapity/listy/kod/emoji/null/nieznany node i limit UTF-8.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/jira_cloud_client_test.exs test/symphony_elixir/jira_adf_test.exs`.
Odbiór: AC05/AC07/AC14. Req request_fun ma asercje endpointów, headers i pól.

### T08. Matcher, baseline i transakcja pierwszego dopasowania

Spec: §6.1, §7.1–7.2. Zależność: T07.
Pliki: nowe `BE/intake/matcher.ex`, `BE/intake/poller.ex`, `BT/intake_matcher_test.exs`,
`BT/intake_poller_test.exs`; rozszerzenie `BE/intake.ex`.

- [ ] T08.1 RED: stary issue z niskim priorytetem na P1 w następnym skanie tworzy sprawę.
- [ ] T08.2 Case + rezerwowane UUID + analiza + delivery + event w jednej transakcji.
- [ ] T08.3 new_matches_only pomija początkowe matches; include_existing przyjmuje je raz.
- [ ] T08.4 Błąd drugiej strony baseline nie aktywuje żadnej generacji; retry jest kompletny.
- [ ] T08.5 Zmiana klucza Jira, spadek/awans priorytetu, powtórka strony i dwa źródła → jeden case.
- [ ] T08.6 Limity 10000/10 min i zmiana konfiguracji w trakcie skanu blokują commit starej generacji.
- [ ] T08.7 Edycja interwału, nowy baseline po filtrze i pauza/wznowienie zgodne ze spec.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_matcher_test.exs test/symphony_elixir/intake_poller_test.exs`.
Odbiór: AC06/AC07/AC08. Nie implementować timestamp-only search ani automatycznego backfillu.

### T09. Scheduler, restart i izolacja błędów reguł

Spec: §6.2, §7.2, §13. Zależność: T08.
Pliki: nowe `BE/intake/scheduler.ex`, `BT/intake_scheduler_test.exs`;
`elixir/lib/symphony_elixir.ex`, `BT/intake_dispatcher_test.exs`.

- [ ] T09.1 RED: dwie reguły z interwałami 60/300 s mają niezależne due_at.
- [ ] T09.2 Claim skanu z lease, heartbeat, cancelled/stale generation; brak overlapping pollów.
- [ ] T09.3 Manual check w trakcie skanu → 409; jeden request nie tworzy wielu scanów.
- [ ] T09.4 Awaria Jira A nie zatrzymuje Jira B ani istniejącego orchestratora Linear.
- [ ] T09.5 Restart odtwarza pending z DB, a błędny last_success nie jest aktualizowany.
- [ ] T09.6 Dodaj supervisor children dopiero z wyłączonym domyślnie runtime intake.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_scheduler_test.exs test/symphony_elixir/intake_dispatcher_test.exs`.
Odbiór: AC07/AC08/AC19. Testy zegara bez długich sleep.

### T10. LinearBridge i odzyskanie po timeout create

Spec: §8.1. Zależność: T05–T09.
Pliki: nowe `BE/intake/linear_bridge.ex`, `BT/intake_linear_bridge_test.exs`;
`BE/linear/client.ex`; zapis fixture GraphQL pod `elixir/test/fixtures/intake/`.

- [ ] T10.1 RED: provider zapisuje issue, odpowiedź ginie, retry nie tworzy drugiego.
- [ ] T10.2 Lookup UUID, create z tym samym UUID, walidacja project/team/state/label.
- [ ] T10.3 Bez Todo lub etykiety nie ma create; nie wybieraj dowolnego pierwszego stanu.
- [ ] T10.4 Tytuł/opis/marker/URL zgodne ze spec; odpowiedź 200 errors nie uwalnia analizy.
- [ ] T10.5 Query odczytu przed create, po konflikcie ID i po crash przed zapisem DB.
- [ ] T10.6 W tym samym teście wstrzyknij poll Linear przed odpowiedzią create: gate odmawia.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_linear_bridge_test.exs test/symphony_elixir/intake_execution_gate_test.exs`.
Odbiór M2: AC05–AC09; jeden case, jeden UUID, zero implementacji przy symulowanej awarii.

## 6. M3 — bezpieczna analiza i decyzja człowieka

### T11. Profil izolacji sesji analitycznej

Spec: §9.1. Zależność: M2.
Pliki: nowe `BE/intake/analysis_policy.ex`, `BT/intake_analysis_policy_test.exs`,
`BT/intake_analysis_policy_giso_test.exs`;
`BE/codex/app_server.ex`, `BE/agent_backends/codex.ex`;
fixture protokołu pod `elixir/test/fixtures/intake/`.

- [x] T11.1 RED/GREEN: profil analizy ma puste `dynamicTools`, nie akceptuje eskalacji, a wymagane
      model/effort i nieobsługiwane pola są walidowane przed startem.
- [x] T11.2 Osobne jawne session opts; istniejące implementacyjne wywołania bez zmiany zachowania.
- [x] T11.3 Test fake app-server potwierdza `permissions` w `thread/start` i `turn/start`,
      brak starych pól sandbox, `outputSchema`, model i effort.
- [x] T11.4 Sanityzuj env i prywatny `CODEX_HOME`; wyłącz MCP/pluginy/hooki i login shell.
      Profil `analysis_ro` nie dziedziczy po `:read-only`, czyta tylko `:minimal`, runtime roots
      i kanoniczny plik wykonywalny Codex; `network.enabled = false`.
- [x] T11.5 Próba konfliktu `permissionProfile`/`sandboxPolicy` → odmowa; dynamic tool → odmowa;
      nieobsługiwane policy field → błąd startu.
- [x] T11.6 Wstępny G-ISO na aktualnie zainstalowanym Codex CLI (w tym przebiegu `0.155.1`),
      bez turnu/modelu: workspace read; odmowa syntetycznego auth i operator config; app-server
      dostaje wyłącznie testowe model API keys, integracyjne sekrety są wyczyszczone, a shell
      nie widzi żadnych canary w env ani czytelnym `/proc/*/environ`; auth pozostaje niedostępny
      przez `/proc/*/root` i `/proc/*/fd`; create/edit/delete blokowane z niezmienionym hashem;
      config workspace próbuje też ustawić `:root = write` i `network.enabled = true` dla
      `analysis_ro`, lecz loopback i zapisy nadal są blokowane. Konflikt override odrzucony;
      test raportuje wersję; pełny G-ISO ponownie w T29.

Testy: `cd elixir && CLOAK_KEY=<synthetic> mise exec -- mix test test/symphony_elixir/intake_analysis_policy_test.exs test/symphony_elixir/app_server_test.exs`;
realny test bez inference: `cd elixir && CLOAK_KEY=<synthetic> mise exec -- mix test test/symphony_elixir/intake_analysis_policy_giso_test.exs`.
Odbiór: AC10/AC14 oraz G-ISO z §10 planu. Bez G-ISO nie wolno włączyć analysis.enabled.

### T12. Snapshot kontekstu repozytorium

Spec: §9.2, §12. Zależność: T11.
Pliki: nowe `BE/intake/analysis_context.ex`, `BT/intake_analysis_context_test.exs`;
rozszerzenie `BE/forge.ex`, `BE/forge/{github,gitlab,memory}.ex` tylko o snapshot read.

- [x] T12.1 RED: archive ../escape lub symlink nie zapisuje nic poza workspace.
- [x] T12.2 Pobierz SHA i archive przez forge; gitlab pełną zakodowaną ścieżką, nie numerem projektu.
- [x] T12.3 Test limitów rozpakowanego rozmiaru/liczby plików i braku wykonywania hooków.
- [x] T12.4 Snapshot nie zawiera .git/config/credentialów; test profilu potwierdza brak
      tokenu pobierania w środowisku narzędzi analizy.
- [x] T12.5 Brak repo → API zwraca jawne issue_only z powodem, nie fałszywą analizę kodu.
- [x] T12.6 Cleanup usuwa wyłącznie konkretny zwalidowany katalog snapshotu po zakończeniu/przerwaniu.

T12 zwraca status i powód jako metadata. T13 zapisuje te wartości w `input_snapshot`
i po próbie usuwa wyłącznie katalog snapshotu dla danego case i wersji.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_analysis_context_test.exs`.
Odbiór: AC10/AC11/AC14; archiwa są syntetyczne i lokalne w testach.

### T13. Runner, wynik JSON i publikacja komentarza

Spec: §9.2–9.3. Zależność: T12.
Pliki: nowe `BE/intake/{analysis_runner,analysis_result,analysis_prompt,comment_renderer,comment_publisher}.ex`;
nowe `BT/intake_analysis_runner_test.exs`, `BT/intake_analysis_result_test.exs`,
`BT/intake_comment_publisher_test.exs`; `BE/intake/dispatcher.ex`.

- [x] T13.1 RED: po prawidłowym wyniku i timeout komentarza model ma być uruchomiony tylko raz.
- [x] T13.2 Runner startuje dopiero po potwierdzonym Linear, jedna tura i deadline całej próby.
- [x] T13.3 Odrzuć malformed/za duży JSON, fałszywe źródło, HTML i niezgodny context_scope.
- [x] T13.4 Prawidłowe needs_input publikuje braki; failed nie publikuje stdout.
- [x] T13.5 Zapis wyniku i delivery komentarza atomowy; marker/property powiązane z wersją.
- [x] T13.6 Po utracie odpowiedzi odczytaj wszystkie strony comments; unknown bez automatycznego POST.
- [x] T13.7 Późny wynik starego lease i v1 po reanalizie v2 nie nadpisują aktywnej wersji.
- [x] T13.8 WorkRun analizy zapisuje status i usage; nie trafia do implementation dispatcher.
- [x] T13.9 Zapisz `input_snapshot`, w tym `issue_only` i powód braku repo, w historii analizy.
- [x] T13.10 Po sukcesie lub przerwaniu usuń wyłącznie konkretny zwalidowany katalog snapshotu.
- [x] T13.11 Potwierdź, że runner nie przekazuje tokenu Forge do sesji analitycznej.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_analysis_runner_test.exs test/symphony_elixir/intake_analysis_result_test.exs test/symphony_elixir/intake_comment_publisher_test.exs`.
Odbiór: AC10/AC11/AC12; żadnej prawdziwej analizy w standardowej komendzie.

### T14. Przyjęcie, reanaliza i zatwierdzenie naprawy

Spec: §4.4, §8.2, §9.2. Zależność: T13.
Pliki: nowy `BE/intake/actions.ex`, `BT/intake_actions_test.exs`; `BE/intake.ex`.

- [x] T14.1 RED: acknowledge nie wywołuje refresh implementation ani nie zapisuje zgody.
- [x] T14.2 Approve wymaga ready, publikacji komentarza, confirmed i aktualnej wersji.
- [x] T14.3 Dwa approve tej samej wersji dają jedną zgodę; stale version zwraca
      `:stale_version` (mapowanie HTTP 409 w T20).
- [x] T14.4 Reanalyze atomowo tworzy następną wersję i czyści acknowledge; po zgodzie odmawia.
- [x] T14.5 Concurrent approve/reanalyze: jedna transakcja wygrywa, druga konflikt; nigdy obie.
- [x] T14.6 Refresh dopiero po commit, a gate wciąż respektuje pozostałe polityki orchestratora.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_actions_test.exs test/symphony_elixir/intake_execution_gate_test.exs`.
Odbiór M3: AC09–AC12/AC15, testy T11–T14 i zaliczona izolacja przed następnym live gate.

## 7. M4 — wysyłka, API i projekcja danych

### T15. SMTP i bezpieczne szablony

Spec: §10.1–10.2. Zależność: M3.
Pliki: nowe `BE/notifications/smtp.ex`, `BE/notifications/templates.ex`,
`BT/notification_smtp_test.exs`, `BT/notification_smtp_integration_test.exs`;
`elixir/mix.exs`, `elixir/mix.lock`, `elixir/test/test_helper.exs`.

- [ ] T15.1 RED: timeout po DATA to unknown, a nie kolejna automatyczna wysyłka.
- [ ] T15.2 Dodaj tylko Swoosh i gen_smtp zgodne z zainstalowanym Elixir; przypnij lockfile.
- [ ] T15.3 TLS verify peer, Message-ID stały per delivery, jeden odbiorca bez ujawniania listy.
- [ ] T15.4 Szablon nie zawiera pełnego opisu, sekretów, fikcyjnego Linear URL; HTML escapowany.
- [ ] T15.5 Test EHLO/STARTTLS/AUTH nie wykonuje DATA; test-send wymaga odrębnej zgody.
- [ ] T15.6 CR/LF w subject/from/recipient odrzucone, nie header injection.
- [ ] T15.7 Przygotuj test Mailpit opisany w §10.5, oznacz smtp_integration;
      domyślnie wyklucz ten tag w test_helper, a jawne --include go uruchamia.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/notification_smtp_test.exs`.
Odbiór: AC13/AC14. Mailpit integration dopiero przy globalnej bramce, nie po każdym zadaniu.

### T16. SMSAPI i kontrola kosztów

Spec: §10.1, §10.3–10.4. Zależność: T15.
Pliki: nowe `BE/notifications/smsapi.ex`, `BT/notification_smsapi_test.exs`;
`BE/intake/dispatcher.ex`, `BE/notifications/templates.ex`.

- [ ] T16.1 RED: 200 z błędem dostawcy nie jest succeeded; duplicate idx nie tworzy nowego idx.
- [ ] T16.2 POST form z Bearer, pola i endpoint zgodne ze spec, bez SDK i parametrów w URL.
- [ ] T16.3 Normalizacja E.164, Unicode/134 jednostki UTF-16, nie ucinać URL.
- [ ] T16.4 Limit 20/h w dwóch równoległych dispatcherach; test-send wliczany do limitu.
- [ ] T16.5 Awaria SMS nie blokuje maila/Linear/analizy; niepewna odpowiedź → unknown.
- [ ] T16.6 Wspólny test: dwa skany, dwa kanały, każdy odbiorca otrzymuje po jednym logicznym delivery.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/notification_smsapi_test.exs test/symphony_elixir/intake_outbox_test.exs`.
Odbiór: AC13/AC14, zero realnych SMS.

### T17. Kontrolery konfiguracji i zabezpieczenie mutacji

Spec: §11.1–11.2, §12. Zależność: T16.
Pliki: nowe `WEB/controllers/{automation,integration,case_action,delivery,linear_options,csrf}_controller.ex`,
`WEB/plugs/operator_mutation.ex`, `WEB/intake_presenter.ex`;
`WEB/router.ex`, `WEB/endpoint.ex`, `FE/lib/api.ts`, nowe `FE/lib/api.test.ts`;
nowe `BT/intake_api_test.exs`, `BT/intake_api_security_test.exs`.

- [ ] T17.1 RED: brak CSRF/obcy Origin/body secret w response → test odmawia przejścia.
- [ ] T17.2 Zaimplementuj endpointy i whitelist params; routes przed catch-all.
- [ ] T17.3 GET /api/v1/csrf, fetch_session/get_csrf_token i no-store zgodnie z §11.1;
      api.ts bootstrapuje token i wysyła wyłącznie do same-origin API. Nie zmieniaj statycznego HTML.
      Test restartu sesji: 403 nie ponawia mutacji, odświeża token i wymaga ponownego działania użytkownika.
- [ ] T17.4 Test formularza PATCH, optimistic lock, 404/409/422/405 oraz brak surowych wyjątków.
- [ ] T17.5 Preview ma zero mutacji zewnętrznych i pokazuje limit/truncated; aktywacja osobna.
- [ ] T17.6 Test-send idempotentny, potwierdzony, limitowany; read-only test nie wysyła wiadomości.
- [ ] T17.7 Nowy guard nie blokuje istniejących webhooków forge wymagających własnej weryfikacji.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_api_test.exs test/symphony_elixir/intake_api_security_test.exs`;
`cd elixir/assets && npm run test -- --run src/lib/api.test.ts`.
Odbiór: AC05/AC14/AC15/AC19. Nie dodawać otwartego proxy do dostawców.

### T18. Cases — lista, szczegół, agregaty i historia

Spec: §11.3. Zależność: T17.
Pliki: nowe `BE/cases.ex`, `BE/cases/projection.ex`, `WEB/controllers/case_controller.ex`,
`BT/cases_projection_test.exs`, `BT/cases_api_test.exs`; `WEB/intake_presenter.ex`.

- [ ] T18.1 RED: 60 spraw w jednej kolumnie, po 25 na stronę, total=60 i kompletna suma projektów.
- [ ] T18.2 PostgreSQL UNION i latest-per-source; nie wczytuj całej historii do Enum.
- [ ] T18.3 Ref jira_/run_, stabilne cursory związane z filtrem, wyszukiwanie po tytule/ID.
- [ ] T18.4 Poprawna kolejność precedence statusów i ukrycie implementation zduplikowanej z case.
- [ ] T18.5 Legacy bez Linear, brak opisu, unknown status i błąd publikacji pozostają widoczne.
- [ ] T18.6 Detail events stronicowane, actions obliczane przez backend; fixture T01 aktualna.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/cases_projection_test.exs test/symphony_elixir/cases_api_test.exs test/symphony_elixir/intake_contract_test.exs`.
Odbiór: AC02/AC04/AC16. Zapytania list/count stała liczba, brak N+1 na karty.

### T19. Phoenix Channel i hooki React Query

Spec: §11.4. Zależność: T18.
Pliki: nowy `WEB/channels/intake_channel.ex`, `WEB/intake_pubsub.ex`, `BT/intake_channel_test.exs`;
`WEB/channels/user_socket.ex`, `FE/lib/api.ts`, `FE/types/contract.ts`;
nowe `FE/features/cases/{useCases,useCase,useCaseEvents,useIntakeChannel}.ts` i testy obok.

- [ ] T19.1 RED: reconnect musi odświeżyć aktywną listę, a channel payload nie zawierać treści/sekretu.
- [ ] T19.2 Event dopiero po commit; transakcja rollback nie wywołuje invalidacji.
- [ ] T19.3 Jeden Socket, subskrypcja sprzątana po unmount, debounce 250 ms i fallback 30 s offline.
- [ ] T19.4 Stare topics/cache bez regresji; zmiana projektu nie pokazuje danych poprzedniego requestu.

Test: `cd elixir && mise exec -- mix test test/symphony_elixir/intake_channel_test.exs`;
`cd elixir/assets && npm run test -- --run src/features/cases src/lib/socket.test.ts src/lib/api.test.ts`.
Odbiór M4: AC13/AC14/AC16/AC17; wszystkie HTTP/delivery adaptery nadal testowe.

## 8. M5 — interfejs zgodny z A

### T20. Tokeny, shell i dane prezentacyjne projektu

Spec: §4.1–4.3. Zależność: M4.
Pliki: `elixir/assets/{AGENTS,CLAUDE}.md`, `FE/index.css`, `FE/App.tsx`,
`FE/components/layout/{AppShell,Sidebar,Breadcrumbs}.tsx` i istniejące testy;
`BE/storage.ex`, `BE/storage/project.ex`, `BE/project_config/{schema,sync}.ex`,
`WEB/controllers/project_controller.ex`, `WEB/presenter.ex`, `FE/types/contract.ts`,
`FE/features/projects/projectSchema.ts`, `FE/routes/ProjectFormPage.tsx`,
`FE/features/project/components/ProjectConfigForm.tsx` i jego test,
`BT/project_config_test.exs`, `BT/storage_test.exs`.

- [ ] T20.1 RED: sidebar ma polskie pozycje i nazwy projektu, aktywny projekt wskazuje filtr spraw.
- [ ] T20.2 Zaktualizuj obie instrukcje motywu po angielsku; zakaz hand-edit ui/* pozostaje.
- [ ] T20.3 Tokeny i typografia A, desktop/mobile shell, menu wysuwane; bez paska koncepcji/profilu demo.
- [ ] T20.4 Nowe route i /overview jako zachowany ekran techniczny; nie usuń run deep-linków.
- [ ] T20.5 display_name/ui_color działają w DB/API/YAML/form; brak pola w YAML nie kasuje ustawienia UI.
- [ ] T20.6 Badge, hover, focus i reduced motion dokładnie §4.2; color nie oznacza health.
- [ ] T20.7 Dark mode zachowuje układ A, nie przełącza na makietę B.

Test: `cd elixir/assets && npm run test -- --run src/components/layout src/App.test.tsx src/components/theme src/features/project/components/ProjectConfigForm.test.tsx`;
`cd elixir && mise exec -- mix test test/symphony_elixir/project_config_test.exs test/symphony_elixir/storage_test.exs`.
Odbiór: AC01/AC03/AC16; zrzuty po T27, teraz testy komponentowe i formularza.

### T21. Centrum spraw — lista i stan URL

Spec: §4.3–4.4. Zależność: T20.
Nowe pliki pod `FE/features/cases/`: `CasesPage.tsx`, `CaseToolbar.tsx`,
`CaseStats.tsx`, `CaseList.tsx`, `CaseListItem.tsx`, `useCaseFilters.ts`,
`CasesPage.test.tsx`, `useCaseFilters.test.ts`.

- [ ] T21.1 RED: przejście po URL z project/q/filter oraz Back/Forward odtwarza wynik.
- [ ] T21.2 Lista domyślna, 25 rekordów + pokaż więcej, dane wyłącznie przez hooki T19.
- [ ] T21.3 Stats i badge używają różnych udokumentowanych zakresów agregacji, nie długości items.
- [ ] T21.4 Szukanie 300 ms debounce, anulowanie starego requestu, reset cursorów, empty result.
- [ ] T21.5 Loading/error/offline i brak Jira reguł to zaprojektowane stany, nie spinner bez końca.
- [ ] T21.6 „Sprawdź teraz”: pending→zakolejkowano, 409/503 obsłużone bez fałszywego sukcesu skanu.
- [ ] T21.7 Preferencja view w localStorage, jawny URL ma pierwszeństwo; nie zapisuj danych spraw.

Test: `cd elixir/assets && npm run test -- --run src/features/cases/CasesPage.test.tsx src/features/cases/useCaseFilters.test.ts`.
Odbiór: AC01/AC02/AC17. Nie importuj danych z app.js makiety do runtime.

### T22. Szczegół, historia i linki Jira/Linear

Spec: §4.4, §8.2, §9. Zależność: T21.
Nowe pliki pod `FE/features/cases/`: `CaseDetail.tsx`, `CaseDetailPage.tsx`,
`CaseAnalysis.tsx`, `CaseHistory.tsx`, `CaseActions.tsx`, `ExternalIssueLink.tsx`,
`useCaseActions.ts`, `CaseDetail.test.tsx`, `CaseActions.test.tsx`.

- [ ] T22.1 RED: Jira/Linear linki mają ten sam variant/size, brak URL wyłącza przycisk.
- [ ] T22.2 Zakładki mają osobne empty/loading/error; nie mieszaj historii dwóch case.
- [ ] T22.3 Fakty/hipotezy/braki i wersja/model/SHA wyświetlone bez raw HTML i fałszywej pewności.
- [ ] T22.4 Acknowledge i approve-repair to dwie różne mutacje; druga ma opisany dialog.
- [ ] T22.5 Stale version i błąd publikacji pokazane przy akcji; backend actions sterują dostępnością.
- [ ] T22.6 Reanaliza ostrzega o koszcie; retry dotyczy delivery, nie całego workflow.
- [ ] T22.7 Mobile detail jako dialog, desktop lista z panelem; deep-link działa samodzielnie.
- [ ] T22.8 Dla legacy agent_work brak fikcyjnej analizy, link do istniejącej historii/dowodów.

Test: `cd elixir/assets && npm run test -- --run src/features/cases/CaseDetail.test.tsx src/features/cases/CaseActions.test.tsx`.
Odbiór: AC04/AC11/AC12/AC15/AC17.

### T23. Kanban — te same dane, osobne strony kolumn

Spec: §4.5, §11.3. Zależność: T22.
Nowe pliki pod `FE/features/cases/`: `CaseBoard.tsx`, `CaseColumn.tsx`,
`CaseBoardCard.tsx`, `CaseBoard.test.tsx`; `CasesPage.tsx`, `useCases.ts`.

- [ ] T23.1 RED: 60 kart w Wykryte, pozostałe kolumny puste; paginacja zwraca wszystkie 60 raz.
- [ ] T23.2 Cztery kolumny w stałej kolejności, breakpointy 1150/850/600 ze spec.
- [ ] T23.3 Lista→Kanban→Lista zachowuje query i wybór, ale nie przenosi niezgodnych cursorów.
- [ ] T23.4 Klik/Enter otwiera wspólny szczegół, Escape przywraca focus do karty.
- [ ] T23.5 Empty i błąd pojedynczej kolumny nie blokują pozostałych; total to nie items.length.
- [ ] T23.6 Bez biblioteki DnD, edycji statusów przez przeciąganie ani nowych mutacji.

Test: `cd elixir/assets && npm run test -- --run src/features/cases/CaseBoard.test.tsx`.
Odbiór: AC01/AC02/AC17.

### T24. Automatyzacje — lista, formularz, dry-run i aktywacja

Spec: §4.6, §7, §11.2. Zależność: T23.
Nowe pliki pod `FE/features/automations/`: `AutomationsPage.tsx`, `AutomationFormPage.tsx`,
`AutomationForm.tsx`, `AutomationPreview.tsx`, `automationSchema.ts`, `useAutomations.ts`,
`AutomationForm.test.tsx`, `AutomationsPage.test.tsx`.

- [ ] T24.1 RED: zapis nie włącza reguły, a preview nie wywołuje activate/check.
- [ ] T24.2 Pickery Jira źródła/priorytetów i Linear z jawnymi ID, loading/error/retry.
- [ ] T24.3 Konwersja sekund/minut/godzin nie zaokrągla cicho; wszystkie granice walidacji.
- [ ] T24.4 Odbiorcy SMTP/SMSAPI jawni, 10 max, obie listy opcjonalne według checkboxów.
- [ ] T24.5 Podgląd plain language, baseline polityka, liczba istniejących matches, collision warning.
- [ ] T24.6 Activate wymaga zapisu i potwierdzenia; edycja w dirty form ostrzega przed utratą zmian.
- [ ] T24.7 Konflikt wersji 409 nie nadpisuje cudzej konfiguracji; pokazuje odświeżenie.
- [ ] T24.8 Pauza/wznowienie i następny termin odzwierciedlają odpowiedź backendu.

Test: `cd elixir/assets && npm run test -- --run src/features/automations`.
Odbiór: AC05/AC06/AC07/AC13; forma zgodna z A, nie edytor JSON reguły.

### T25. Integracje — konfiguracja i stany dostawców

Spec: §4.6, §10–12. Zależność: T24.
Nowe pliki pod `FE/features/integrations/`: `IntegrationsPage.tsx`,
`IntegrationForm.tsx`, `TestDeliveryDialog.tsx`, `integrationSchema.ts`,
`useIntegrations.ts`, `IntegrationsPage.test.tsx`, `IntegrationForm.test.tsx`.

- [ ] T25.1 RED: maskowany zapisany sekret nie wraca jako wartość input ani do localStorage.
- [ ] T25.2 Jira classic/scoped z poprawnymi wymaganymi polami, SMTP TLS/host, SMSAPI nadawca.
- [ ] T25.3 Karta Linear korzysta z projektu i istniejącego sekretu; nie tworzy connection kind linear.
- [ ] T25.4 Test connection bez wysyłki; test-send osobny dialog, odbiorca, koszt i Idempotency-Key.
- [ ] T25.5 clear_secret odrębne potwierdzenie; disabled connection pokazuje zatrzymane efekty.
- [ ] T25.6 Unknown/preflight failed to konkretne wskazówki, nie zielony „Połączono”.

Test: `cd elixir/assets && npm run test -- --run src/features/integrations`.
Odbiór M5: AC01–AC05/AC13/AC14/AC17; unit/typecheck/lint frontendu, jeszcze bez produkcyjnego intake.

## 9. M6 — regresja i wydanie

### T26. Spójność starych ekranów i diagnostyka

Spec: §4.6, §11.3, §12. Zależność: M5.
Pliki: `FE/features/{overview,project,projects,run,runtime}/`, `FE/routes/`,
`FE/components/{StatusBadge,ErrorBoundary}.tsx` i odpowiadające istniejące testy;
`WEB/presenter.ex` tylko addytywne dane diagnostyczne, nowy `BT/intake_diagnostics_test.exs`.

- [ ] T26.1 RED: istniejące deep-linki, Stop/Retry, dowody/logi i konfiguracja są nadal osiągalne.
- [ ] T26.2 Polskie etykiety i tokeny A we wszystkich ekranach; nie zmieniaj surowych danych trackerów.
- [ ] T26.3 Diagnostyka pokazuje kolejki, unknown, lease, ostatnie sukcesy i pulę analizy.
- [ ] T26.4 Nie nazywaj soft-stop „zabiciem procesu”; regresja API stop/retry bez zmiany kontraktu.
- [ ] T26.5 Usuń wyłącznie rzeczywiście zastąpione nieużywane komponenty/importy/style/dependencies.
      Nie usuwaj Overview, bo pozostaje na /overview, ani historii przebiegów.

Test: `cd elixir/assets && npm run test -- --run src/features src/routes src/components`;
`cd elixir && mise exec -- mix test test/symphony_elixir/intake_diagnostics_test.exs test/symphony_elixir/orchestrator_actions_test.exs`.
Odbiór: AC01/AC16/AC17/AC19.

### T27. Deterministyczne E2E i regresja wizualna

Spec: §4 i AC01–AC04/AC16–AC17. Zależność: T26.
Pliki: nowe `elixir/assets/e2e/{cases,automations,integrations}.spec.ts`,
`harmony-visual.spec.ts`; istniejący `react-spa.spec.ts`,
`elixir/lib/mix/tasks/harmony.react_spa_e2e_server.ex`.

- [ ] T27.1 RED: dodaj przepływy na fixture T01, bez interceptu zastępującego całą aplikację obrazkiem.
- [ ] T27.2 Desktop: wszystkie projekty→Finanse→Lista/Kanban→szczegół→oba linki→powrót.
- [ ] T27.3 Mobile 390×844: hamburger, wybór projektu, dialog, focus restore, zero horizontal overflow.
- [ ] T27.4 Sprawdź 1440×1050, 1024×900, 768×1024 i 390×844, także dark/reduced motion.
- [ ] T27.5 Hover/focus wszystkich trzech kolorów: wyliczony kolor tła i biała kropka,
      duration 200 ms lub 0 przy reduced motion. Zrzut po zakończeniu transition.
- [ ] T27.6 Filtry, wyszukiwanie, Back/Forward, reload i per-column pokaż więcej.
- [ ] T27.7 Formularz: 15 min, jeden priorytet, oba kanały, zapisz→preview→potwierdź;
      test backend zapewnia brak efektów przy samym preview.
- [ ] T27.8 401/403/429/timeout/offline/reconnect/empty i konflikt zapisu mają widoczny stan.
- [ ] T27.9 Screenshoty bazowe zatwierdza człowiek przez porównanie z A.
      Zabronione automatyczne `--update-snapshots` tylko po to, aby test przeszedł.

Test: `cd elixir && mise exec -- make e2e`.
Odbiór: brak błędów console, pełne dowody wizualne, aktywne kontrole dostępne klawiaturą.
Przeglądarkę/testowy serwer uruchamiaj tylko na ten etap i wyłącz po nim.

### T28. Dokumentacja operacyjna i procedura rollback

Spec: §12–14. Zależność: T27.
Pliki: `README.md`, `elixir/README.md`, `elixir/WORKFLOW.md`,
`docs/harmony-operations.md`, `docs/operations/credential-key.md`.

- [ ] T28.1 Opisz wymagane uprawnienia Jira/Linear, Todo/hold label, SMTP TLS i SMSAPI.
- [ ] T28.2 Podaj pełny przykład runtime config z wyłączonymi flagami i bez prawdziwych sekretów.
- [ ] T28.3 Opisz new_matches_only/include_existing, interval, limity, koszty SMS i accepted≠delivered.
- [ ] T28.4 Osobna procedura unknown: sprawdzenie u dostawcy, decyzja o retry, ostrzeżenie o duplikacie.
- [ ] T28.5 Opisz backup DB/CLOAK_KEY, rotację sekretów i zakaz rollbacku binarium bez guard.
- [ ] T28.6 Usuń nieaktualne instrukcje wyglądu/aktywacji dotyczące zastąpionych ekranów,
      nie zmieniaj dokumentów historycznych udających aktualny opis.
- [ ] T28.7 Dokumenty edytowane mają prawidłowy frontmatter i przechodzą markdownlint.

Test: `npx --yes markdownlint-cli2 README.md elixir/README.md elixir/WORKFLOW.md docs/harmony-operations.md docs/operations/credential-key.md`.
Odbiór: AC19, kompletna instrukcja bez produkcyjnych tokenów/adresatów.
Nie dodawać odwołań do prywatnych skilli tej stacji w instrukcjach repo.

### T29. Pełna weryfikacja i kontrolowane uruchomienie

Zależność: T00–T28. Nie zaczynać przed akceptacją wyników M0–M5 i G-ISO.

- [ ] T29.1 Wykonaj pełne bramki §10; każda komenda ma prawdziwy exit code.
- [ ] T29.2 Uruchom scenariusz restart/fault-injection §10.2 na testowej PostgreSQL.
- [ ] T29.3 Przeprowadź G-LIVE wyłącznie po uzyskaniu zgody na konkretne zasoby i adresatów.
- [ ] T29.4 Koordynator niezależnie powtarza targeted testy i sprawdza screenshoty.
- [ ] T29.5 Przegląd diff: brak sekretów, fikcyjnych danych runtime, pominiętych AC i martwego UI.
- [ ] T29.6 Raport zawiera worktree, branch, PR, wszystkie kody wyjścia i otwarte punkty.
- [ ] T29.7 Produkcyjne enabled=true dopiero decyzją operatora; sam zielony CI nie jest zgodą.

## 10. Bramki walidacyjne

### 10.1. Polecenia globalne

Poniższe komendy są wymagane na końcu całego planu. W trakcie zadań uruchamiać
targeted unit testy; nie podnosić całej integracji po każdej małej zmianie.
`make all` nie zastępuje frontend Vitest/lint/E2E — Makefile nie uruchamia ich wszystkich.

Z repo root:

```bash
npx --yes markdownlint-cli2 docs/superpowers/specs/2026-09-22-harmony-ui-jira-design.md docs/superpowers/plans/2026-09-22-harmony-ui-jira.md
git diff --check
```

Z katalogu `elixir/`:

```bash
mise exec -- mix format --check-formatted
mise exec -- mix specs.check
mise exec -- mix test
mise exec -- make all
mise exec -- make e2e
```

Z katalogu `elixir/assets/`:

```bash
npm run test -- --run
npm run typecheck
npm run lint
npm run build
```

Każdą komendę uruchamiać osobno i zachować stdout/stderr oraz exit code.
Nie przepuszczać przez tail/head; pipeline bez pipefail nie jest dowodem sukcesu.
Pełne logi w lokalnym `output/verification/<milestone>/`; do PR wkleić streszczenie
i artefakty bez sekretów. Przed deklaracją gotowości pokazać kody 0 wszystkich bramek.

### 10.2. Wymagana macierz fault-injection

Wszystkie scenariusze to automatyczne testy z stubami transportu i prawdziwą DB.
Restartować procesy testowego supervisora, nie usługę użytkownika.

| Punkt awarii                                    | Oczekiwany wynik                                                  |
| ----------------------------------------------- | ----------------------------------------------------------------- |
| Przed commit kwalifikacji                       | Nie ma case ani efektów; następny poll przyjmuje raz              |
| Po commit, przed claim                          | Case i delivery przetrwają restart                                |
| Dwa pollery widzą issue jednocześnie            | Jeden case i jeden komplet delivery                               |
| Linear utworzył issue, odpowiedź zginęła        | Lookup tego samego UUID, zero drugiego create z nowym ID          |
| Poll Linear w trakcie create                    | Gate widzi zarezerwowane UUID/marker i nie startuje implementacji |
| Model skończył, DB zapis wyniku nie powiódł się | Brak komentarza bez trwałego wyniku; jawny retry/limit próby      |
| Wynik zapisany, komentarz 403                   | Wynik dostępny, retry publikacji bez ponownego modelu             |
| Komentarz dodany, odpowiedź zginęła             | Odnalezienie markera albo unknown, nie blind POST                 |
| SMTP po DATA timeout                            | Unknown, brak automatycznego resend                               |
| SMSAPI duplicate idx                            | Brak nowego idx/wiadomości; stan już przyjęte                     |
| Jeden kanał failed                              | Drugi i analiza nie zatrzymują się                                |
| Lease wygaśnie, stary worker wraca              | CAS odrzuca późny wynik                                           |
| Zapis zmienia regułę podczas baseline           | Stary config_version nie aktywuje reguły                          |
| Approve i reanalyze równocześnie                | Jedna decyzja wygrywa, druga 409                                  |
| DB niedostępna podczas dispatch                 | Brak implementacji importu i brak fallbacku in-memory             |
| intake/effects wyłączone po restarcie           | Brak nowych efektów; guard nadal chroni Todo                      |

### 10.3. G-ISO — rzeczywista izolacja analizatora

Wstępna bramka T11.6 działa bez inference na izolowanym katalogu i syntetycznym
`CODEX_HOME/auth.json`. Test używa lokalnego Codex CLI 0.155.1 i rzeczywistego `command/exec`
z `permissionProfile = analysis_ro`; nie tworzy turnu ani `WorkRun` i nie nalicza tokenów.

- [x] `thread/start.permissions` wybiera istniejący profil; `permissionProfile/list` widzi go;
      `command/exec` z tym profilem odczytuje plik workspace.
- [x] Shell nie może odczytać syntetycznego `auth.json` ani operatorowego `config.toml` poza
      root ani odziedziczyć żadnych syntetycznych kluczy API; skan czytelnych
      `/proc/*/environ` też nie znajduje canary, a `/proc/*/root` i `/proc/*/fd` nie ujawniają
      auth. Proces app-server otrzymuje klucze API modelu, a `CLOAK_KEY`, Jira, Linear i SMTP
      canary są z niego usunięte.
- [x] Utworzenie, edycja i usunięcie pliku-canary są blokowane przez system; hash pozostaje
      identyczny, również gdy workspace zawiera testowy `.codex/config.toml` z `sandbox_mode`
      ustawionym na `danger-full-access` i `[permissions.analysis_ro.filesystem]` ustawiającym
      `:root = write`; override `analysis_ro.network.enabled = true` też nie otwiera loopback.
- [x] Połączenie do host-side loopback listenera jest blokowane; listener nie przyjmuje połączenia.
- [x] Konflikt `permissionProfile` z `sandboxPolicy` jest odrzucony; fake app-server potwierdza
      brak dynamicTools i brakuje decyzji auto-approve dla eskalacji.
- [ ] Pełny turn modelu: rzeczywiste polecenia generowane przez model, odmowa eskalacji oraz
      oddzielenie network narzędzi od ruchu inference.
- [ ] Runner T13/T29: hooki repo i instrukcja Jira żądające zapisu/sendu nie są wykonane;
      timeout kończy sesję, a późny wynik nie zapisuje sukcesu.

Dowód T11.6: wersja CLI, `permissionProfile/list`, odpowiedzi `thread/start` i `command/exec`,
syntetyczne canary, hashe pliku i exit codes w teście
`elixir/test/symphony_elixir/intake_analysis_policy_giso_test.exs`. Otwarty pełny gate oznacza,
że `analysis.enabled` pozostaje `false`; bezpieczny prompt nie zastępuje systemowej izolacji.

### 10.4. G-LIVE — kontrolowana integracja

Wymagane dane operatora przed startem: testowa Jira site/board/filter/priorities,
testowy projekt/team Linear z Todo, jeden adres SMTP i jeden numer SMSAPI,
zatwierdzony koszt SMS/analizy, publiczny URL Harmony oraz wybrany model analizy.
Nie umieszczać tokenów w raporcie ani ticketach.

- [ ] Utwórz regułę disabled, dry-run potwierdza źródło, match_count i zero zapisów.
- [ ] Aktywuj new_matches_only; istniejący priorytetowy ticket nie uruchamia alertu.
- [ ] W uzgodnionym testowym tickecie podnieś priorytet; po interwale jeden case,
      jeden Linear Todo, jeden mail i jeden SMS na wskazanego odbiorcę.
- [ ] Poczekaj na analizę; Jira ma jeden komentarz, Harmony te same ustalenia i oba linki.
- [ ] Poczekaj kolejny interwał i zrestartuj tylko testową aplikację; brak duplikatów/naprawy.
- [ ] Przyjmij sprawę; nie uruchamia naprawy. Approval naprawy testować wyłącznie
      na osobnym testowym repo i tylko za odrębną zgodą operatora.
- [ ] Wyłącz regułę; następny ticket nie powoduje efektów. Wyłączenie intake nie wyłącza guard.
- [ ] Sprawdź w dostawcach przyjęcie wiadomości; UI nie obiecuje potwierdzonego doręczenia.

Dowód: URL testowych ticketów, case UUID, rule ID, delivery provider IDs,
work_run UUID, timestampy, screenshoty, komendy i wyniki. Odbiorcy maskowani.
Po teście reguła i wysyłki testowe wyłączone. Nie usuwać zgłoszeń/wiadomości
bez osobnej zgody; raportuje się powstałe zasoby.

### 10.5. G-SMTP — lokalny test transportu

Na granicy planu uruchomić z katalogu elixir:

```bash
mise exec -- mix test test/symphony_elixir/notification_smtp_integration_test.exs --include smtp_integration
```

Test sam uruchamia jeden efemeryczny kontener Mailpit z unikalną nazwą i wolnymi
portami związanymi wyłącznie z 127.0.0.1. Wersję obrazu przypiąć w fixture T15,
bez latest; użyć dostępnego silnika Podman lub Docker, brak silnika oznacza
niezaliczoną bramkę, nie skip. Kontener bez wolumenu i bez upstream SMTP.
Wysłać przez produkcyjny adapter jeden mail do syntetycznego odbiorcy, przez API
Mailpit zweryfikować odbiorcę, subject, escapowany HTML i stabilny Message-ID.
Konfiguracja bez TLS dopuszczona tylko dla tego loopback fixture; ustawienia
produkcyjne nadal odrzucają wyłączenie TLS. W cleanup zatrzymać i usunąć tylko
dokładny kontener utworzony przez ten test; nie używać prune ani usuwać wolumenów.
Dowód: komenda, exit code 0 i asercje odczytu z Mailpit. Ten gate nie zastępuje
G-LIVE dla firmowego SMTP/TLS ani testu niepewnego wyniku po DATA.

## 11. Śledzenie wymagań

| AC   | Główne zadania / dowód                                |
| ---- | ----------------------------------------------------- |
| AC01 | T20–T27, screenshoty A we wszystkich viewportach      |
| AC02 | T18, T21, T23, T27; filtry, deep-linki, 60 kart       |
| AC03 | T20 i T27; computed styles hover/focus/reduced motion |
| AC04 | T01, T18, T22, T27; rzeczywiste i brakujące URL       |
| AC05 | T03, T07, T10, T17, T24; granice i Todo/team          |
| AC06 | T08, G-LIVE; pierwszy awans priorytetu                |
| AC07 | T08–T09, T24; baseline/pauza/paginacja                |
| AC08 | T02, T04, T08–T10; współbieżność i fault-injection    |
| AC09 | T05–T06, T10, T14; zero startów przed zgodą           |
| AC10 | T11–T13, G-ISO; rzeczywista izolacja                  |
| AC11 | T12–T13, T22; źródła i walidacja JSON                 |
| AC12 | T13, T22; retry komentarza bez modelu                 |
| AC13 | T04, T15–T17, T25; niezależne kanały i unknown        |
| AC14 | T02–T03, T06–T07, T11–T12, T15–T17, T25; security     |
| AC15 | T05, T14, T22; odrębne akcje, optimistic lock         |
| AC16 | T06, T18, T20, T26–T27; regresja starych przepływów   |
| AC17 | T19, T21–T27; reconnect, error, empty, offline        |
| AC18 | T29; wszystkie pełne logi i kody wyjścia              |
| AC19 | T03–T05, T09, T17, T26, T28–T29; flagi i rollback     |

## 12. Przekazanie do tańszego modelu

Na dzień przygotowania dokumentów:

- Worktree: `/home/ddziag/projects/Harmony`.
- Gałąź dokumentacji: `docs/harmony-ui-jira-spec-plan`.
- PR: nie utworzono; `gh` nie jest zainstalowane, sprawdzono dwukrotnie.
  Repo jest na GitHub; nie publikować dokumentów do innego repo/serwisu jako obejścia.
- Kod funkcji: niezaimplementowany; wszystkie checkboxy celowo puste.
- Decyzje dostawców: Jira Cloud, SMTP, SMSAPI — potwierdzone, nie wymagają ponownego wyboru.
- Otwarte punkty przed wykonaniem: zatwierdzenie spec/plan, publikacja Draft PR,
  udostępnienie zasobów testowych wyłącznie przed G-LIVE i jawny wybór modelu analizy przy wdrożeniu.

Polecenie startowe dla modelu wykonawczego:

```text
Pracujesz w repo Harmony. Wykonaj wyłącznie T00 z dokumentu
docs/superpowers/plans/2026-09-22-harmony-ui-jira.md.
Specyfikacja: docs/superpowers/specs/2026-09-22-harmony-ui-jira-design.md.
Przeczytaj instrukcje repo i sekcję „Kontrakt wykonania”.
Zaakceptowany wygląd to wariant A w docs/mockups, z Lista/Kanban.
Nie projektuj alternatyw, nie uruchamiaj integracji produkcyjnych,
nie przechodź do T01. Zwróć raport w formacie planu z dosłownymi
komendami, surowymi wynikami, exit codes i otwartymi punktami.
```

Po odbiorze T00 koordynator zleca T01 temu samemu wykonawcy, z jego zależnościami.
Przy zmianie modelu przekazuje spec, plan i ostatni raport, nie cały czat projektowy.
Wykonawca otrzymuje jawnie model/tier i effort wybrane przez koordynatora; nie dziedziczy
ich przypadkowo. Ten dokument nie uruchamia agentów i nie instaluje narzędzi.
