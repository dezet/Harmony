---
title: "Harmony — Centrum spraw i automatyzacja Jira Cloud"
date: 2026-09-22
status: proposed
audience: implementation-agent
baseline_commit: ba3ae25d191a4ca771242ae3be54b4fcb071d646
implementation_plan: ../plans/2026-09-22-harmony-ui-jira.md
---

# Harmony — Centrum spraw i automatyzacja Jira Cloud

## 1. Cel i granice dokumentu

Harmony ma prezentować sprawy i wymagane decyzje, a nie przede wszystkim stan procesów agenta.
Wzorcem wizualnym jest zaakceptowana makieta A z opcjonalnym Kanbanem.
Jira dostarcza zgłoszenia do analizy; Linear pozostaje koordynatorem dalszej pracy.

Dokument opisuje pełny zakres uzgodniony 22 września 2026 r. oraz zamyka decyzje
techniczne proponowane do zatwierdzenia wraz z planem. Nie jest zgodą na wysyłanie
wiadomości, uruchamianie agentów ani modyfikowanie produkcyjnych zgłoszeń podczas implementacji.
Odbiorca: model implementujący zadania z [planu](../plans/2026-09-22-harmony-ui-jira.md).
Zakres nie obejmuje terminów kalendarzowych ani szacunków kosztów dostawców.

### 1.1. Hierarchia źródeł

1. Ustalenia użytkownika zapisane w §3 i ograniczenia bezpieczeństwa w §9.
2. Ten dokument: zachowanie, kontrakty, błędy i kryteria odbioru.
3. `docs/mockups/index.html`, `styles.css`, `app.js`, wyłącznie wariant A:
   kompozycja, odstępy, kolory i interakcje wizualne.
4. Plan: kolejność i sposób weryfikacji; nie zmienia zakresu specyfikacji.
5. Starsze dokumenty: kontekst, nie podstawa do odtworzenia odrzuconego wyglądu.

Makieta jest lokalnym, statycznym wzorcem, nie produkcyjnym frontendem.
Nie kopiować do aplikacji jej fikcyjnych danych, toastów udających integracje,
globalnego stanu JavaScript, identyfikatorów ani przełącznika A/B/C.
Konflikt specyfikacji z kodem wymaga zgłoszenia; wykonawca nie rozstrzyga go sam.

## 2. Zweryfikowana baza kodu

Stan: commit z frontmatter; `git ls-remote origin refs/heads/main` wskazywał ten sam SHA.
Repozytorium ma `origin=https://github.com/dezet/Harmony.git`, nie GitLab.

| Obszar   | Istniejące pliki względem katalogu głównego                                                                | Wniosek                                                                                                  |
| -------- | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| SPA      | `elixir/assets/src/App.tsx`, `components/layout/{AppShell,Sidebar,Breadcrumbs}.tsx`                        | React Router, istniejący shell i głębokie linki                                                          |
| UI       | `elixir/assets/src/index.css`, `assets/CLAUDE.md`, `assets/AGENTS.md`                                      | shadcn Base UI/base-nova, Tailwind; obecna zasada domyślnego motywu wymaga jawnej aktualizacji           |
| Dane UI  | `elixir/assets/src/lib/{api,socket}.ts`, `types/contract.ts`                                               | React Query + Phoenix Channels; brak fetch w komponentach                                                |
| Projekty | `storage/project.ex`, `project_config/{schema,loader,sync}.ex` pod `elixir/lib/symphony_elixir/`           | PostgreSQL, YAML, szyfrowane sekrety forge i Linear                                                      |
| Praca    | `elixir/lib/symphony_elixir/{work_run,storage,orchestrator}.ex`                                            | Trwałe przebiegi, deduplikacja, istniejące retry/reconciliation                                          |
| Linear   | `tracker.ex`, `linear/{client,adapter,issue}.ex`, `work_sources/linear_issue_source.ex`                    | Tracker Linear/memory; kandydat staje się `implementation`                                               |
| Statusy  | `elixir/lib/symphony_elixir/config/schema.ex`                                                              | `Todo` i `In Progress` są domyślnie aktywne                                                              |
| Agent    | `agent_runner.ex`, `workspace.ex`, `codex/{app_server,dynamic_tool}.ex`                                    | Hooki workspace i narzędzie GraphQL mogą wykonywać zapisy; nie wolno użyć ich bez ograniczeń dla analizy |
| Historia | `elixir/lib/symphony_elixir_web/controllers/{run_detail,work_run,project_activity,artifact}_controller.ex` | Zachować historię, artefakty, stop/retry i diagnostykę                                                   |
| Start    | `elixir/lib/symphony_elixir.ex`                                                                            | Tutaj znajduje się `SymphonyElixir.Application`; nie tworzyć drugiego Application                        |
| Testy    | `elixir/Makefile`, `elixir/assets/package.json`, `elixir/assets/playwright.config.ts`                      | ExUnit, Vitest, RTL, istniejący deterministyczny Playwright                                              |

Nie dodawać drugiego frameworka frontendowego, drugiej bazy, Redis ani osobnego serwisu HTTP.
Nie przepisywać całego orchestratora. Nowa funkcja ma własny kontekst domenowy `Intake`.

## 3. Zamknięte decyzje

| ID  | Decyzja                                                                                                                |
| --- | ---------------------------------------------------------------------------------------------------------------------- |
| D01 | Wygląd A, jasny domyślnie; Lista i Kanban są dwoma widokami tych samych spraw.                                         |
| D02 | Jira Cloud, REST v3; Jira Data Center/Server i webhooki Jira poza zakresem.                                            |
| D03 | Reguła wybiera jedno połączenie Jira, tablicę albo zapisany filtr, priorytety i interwał.                              |
| D04 | Reagujemy na pierwsze zaobserwowane dopasowanie, również po podniesieniu priorytetu starego zgłoszenia.                |
| D05 | Jedna sprawa na stabilne ID zgłoszenia w instancji Jira; ponowne dopasowanie nie tworzy kopii.                         |
| D06 | Alert e-mail/SMS powstaje po wykryciu; nie czeka na Linear ani analizę. Kanały są niezależne.                          |
| D07 | E-mail przez firmowy SMTP, SMS przez SMSAPI; wybór potwierdzony przez użytkownika.                                     |
| D08 | Linear otrzymuje Todo i trwałą ochronę przed implementacją. Sama zmiana statusu nie jest zgodą na naprawę.             |
| D09 | Analiza i publikacja komentarza nie uruchamiają implementacji. „Przyjmij sprawę” też jej nie uruchamia.                |
| D10 | Naprawa wymaga osobnej, potwierdzonej akcji „Rozpocznij naprawę”; korzysta z istniejącej ścieżki Linear.               |
| D11 | Reguły, sprawy, wyniki i kolejka efektów są trwałe w PostgreSQL, nie w pamięci procesu.                                |
| D12 | Trwała kolejka jest małym modułem Ecto z leasingiem; nie wprowadzamy Oban ani ogólnej platformy workflow.              |
| D13 | W pierwszym wydaniu brak drag-and-drop Kanbana. Kolumny pokazują fakty, nie nadają uprawnień.                          |
| D14 | UI po polsku; identyfikatory, nazwy projektów i treść zgłoszeń pozostają oryginalne.                                   |
| D15 | Obecne funkcje pracy agentów, konfiguracja, historia, logi i dowody pozostają dostępne.                                |
| D16 | Model analizy i model wykonujący ten plan są oddzielnymi wyborami; plan nie zmienia automatycznie konfiguracji modelu. |

Rozważone alternatywy: zastąpienie Linear przez Jira odrzucono, ponieważ zmieniłoby
istniejący proces wieloagentowy. Wysłanie zwykłego Todo bez bariery odrzucono, ponieważ
uruchamia implementację. Wyłącznie frontendowa blokada jest niewystarczająca.
Ogólny kreator automatyzacji i nowy scheduler zewnętrzny są zbędne dla tego zakresu.

Poza zakresem: konta użytkowników i RBAC, wielodzierżawność, Slack/Teams, analityka kosztowa,
nowe backendy agentów, synchronizacja dwukierunkowa wszystkich pól Jira–Linear,
edycja kodu przez analizator, automatyczne mergowanie i zmiana polityk istniejących projektów.
Trusted environment pozostaje warunkiem wdrożenia, nie obietnicą bezpieczeństwa publicznego SaaS.

## 4. Kontrakt wyglądu i nawigacji

### 4.1. Motyw i układ

Aktualizacja `elixir/assets/AGENTS.md` i `CLAUDE.md` ma jawnie zastąpić wymaganie
„default theme” motywem A. Pliki harnessu pozostają po angielsku.
Pozostają shadcn Base UI i zakaz ręcznego modyfikowania `components/ui/*`.
Motyw realizować tokenami `index.css`, układ klasami Tailwind i komponentami feature.

| Token/element                 | Wartość jasnego wariantu                                                       |
| ----------------------------- | ------------------------------------------------------------------------------ |
| Tło                           | `#f8f9fb`                                                                      |
| Powierzchnia                  | `#ffffff`                                                                      |
| Sidebar/kolumny               | `#f3f4f7`                                                                      |
| Tekst główny                  | `#20242f`                                                                      |
| Tekst pomocniczy              | `#687183`                                                                      |
| Obramowanie                   | `#e6e8ee`                                                                      |
| Akcent                        | `#6052d5`                                                                      |
| Jasny akcent                  | `#efedfc`                                                                      |
| Sukces                        | `#237655` na `#eaf5ee`                                                         |
| Ostrzeżenie                   | `#936018` na `#fcf3df`                                                         |
| Błąd                          | `#b74551` na `#fcecee`                                                         |
| Font                          | `Inter, Segoe UI, Arial, sans-serif`; bez pobierania fontów z zewnętrznego CDN |
| Rozmiar bazowy / tytuł strony | 14 px / 29 px, nagłówek 650, line-height 1.2                                   |
| Sidebar desktop               | 218 px; 185 px w zakresie 851–1150 px                                          |
| Padding strony                | 32 px desktop, 25×22 px do 1150 px, 22×16 px do 600 px                         |
| List-detail                   | `minmax(270px, .82fr) minmax(0, 1.3fr)`; proporcje z makiety                   |
| Karty / panel listy           | promień 7–11 px zgodnie z odpowiednim selektorem makiety                       |

Nie dodawać fontu Inter jako nowej zależności: w środowisku bez Inter używać tego samego
fallbacku co makieta. Istniejący dark mode zachować jako drugorzędny: te same układy,
kontrastowe obecne ciemne powierzchnie, fioletowy akcent, bez przełączania do projektu B.
Geist usunąć z importu/dependencies dopiero po potwierdzeniu braku innych użyć.

Górny pasek wyboru koncepcji i napisy „Prototyp/PODGLĄD” nie trafiają do produkcji.
Nie pokazywać fikcyjnego profilu Daniel, avatara ani przełącznika zespołu:
bez uwierzytelniania w stopce jest „Przestrzeń zespołu” i prawdziwy stan połączenia.

### 4.2. Sidebar i badge projektów

Kolejność: logo Harmony, Centrum spraw, Automatyzacje, Integracje, Projekty,
Wszystkie projekty; na dole Diagnostyka, stan połączenia i przełącznik motywu.
„Wszystkie projekty” otwiera istniejący katalog `/projects`; klik projektu
otwiera Centrum spraw z `project=<slug>`, nie usuwa dostępu do workspace projektu.
Nagłówek wybranego projektu ma link „Praca agentów i ustawienia” do `/projects/:slug`.

Kolor projektu nie oznacza zdrowia. Dodać do projektu `display_name` i
`ui_color` z enum `purple|gold|teal`, domyślnie `purple`; brak nazwy → slug.
W formularzu edycji: nazwa 1–100 znaków oraz trzy próbki koloru.
Nowe opcjonalne pola w YAML mają te same nazwy; sync nie nadpisuje wartości UI,
jeśli pole nie występuje w YAML. Istniejące wpisy nie tracą konfiguracji ani sekretów.

Kolory: purple `#7866b5`, gold `#966d24`, teal `#397e6b`.
Kropka 7 px; badge min-width 23 px, height 21 px, padding 0 6 px, radius 6 px,
font 10 px/600, cyfry tabularne. Badge pokazuje wszystkie sprawy projekcji z §11.3,
nie liczbę załadowanych rekordów ani aktywnych procesów; zera pozostają widoczne.
Do 999 pełna liczba, powyżej `999+`, pełna liczba w nazwie dostępności.

Hover i focus klawiatury: cały wiersz w kolorze projektu, tekst/kropka/badge białe,
tło badge białe z alpha 15%, kropka skala 1.15. Przejście koloru i transformacji
200 ms ease. Aktywny wiersz bez hover: tint 12% koloru na sidebarze.
Przy `prefers-reduced-motion: reduce`: bez animacji, stan końcowy identyczny.
Focus ring ma pozostać widoczny; stan aktywny ma `aria-current`, nie tylko kolor.

### 4.3. Trasy i stan widoku

| Trasa                                              | Zawartość                                                  |
| -------------------------------------------------- | ---------------------------------------------------------- |
| `/`                                                | Centrum spraw; domyślnie Lista, wszystkie projekty         |
| `/?project=&view=&filter=&q=&case=&tab=`           | Ten sam ekran z odtwarzalnym wyborem                       |
| `/cases/:ref`                                      | Samodzielny szczegół sprawy; kanoniczny link z powiadomień |
| `/automations`                                     | Lista reguł i ich stan                                     |
| `/automations/new`, `/automations/:id`             | Edytor reguły                                              |
| `/integrations`                                    | Jira, Linear, SMTP, SMSAPI i ich testy połączenia          |
| `/projects`, `/projects/new`, `/projects/:id/edit` | Istniejący CRUD w nowym wyglądzie                          |
| `/projects/:slug`                                  | Istniejące Praca/Dowody/Aktywność/Konfiguracja             |
| `/projects/:slug/runs/:identifier`                 | Zachowany szczegół przebiegu                               |
| `/overview`, `/runtime`                            | Istniejące podsumowanie techniczne i diagnostyka           |

`view=list|kanban`, `filter=all|decision|analysis|done`,
`tab=analysis|issue|history`. Nieprawidłowy enum normalizować przez replace do domyślnego.
Nieistniejący projekt/sprawa ma 404 z powrotem, nie cichy powrót do wszystkich danych.
URL ma pierwszeństwo nad preferencją `localStorage['harmony.case-view.v1']`.
Zapisać tam tylko widok, nigdy sekrety, odbiorców, opisy ani wynik analizy.
Przełączanie Lista/Kanban zachowuje filtry, wyszukiwanie i zaznaczenie; Back/Forward działa.
Zmiana projektu/filtra/wyszukiwania czyści cursory i wybór sprawy spoza wyniku.
Wyszukiwanie po tytule i identyfikatorach Jira/Linear: trim, case-insensitive,
debounce 300 ms, maksymalnie 200 znaków. Parametry budować przez URLSearchParams.

### 4.4. Centrum spraw, lista i szczegół

Nagłówek, krótki opis, „Reguły Jira”, „Sprawdź teraz”, pasek liczników,
filtry, wyszukiwarka, przełącznik widoku — jak w A.
Statystyki do decyzji/w analizie/w kolejce liczone dla projektu, niezależnie od `q`
i aktywnego filtra. Badge filtrów uwzględniają projekt i `q`, nie aktywny filtr.
Liczby muszą pochodzić z zapytań agregujących, nie z pierwszej strony wyników.
Ostatnie i następne sprawdzenie pochodzą z backendu; brak reguł → „Brak aktywnych reguł”.
„Sprawdź teraz” kolejkuje sprawdzenie aktywnych reguł danego zakresu i wywołuje
dotychczasowe odświeżenie Linear; nie oznacza synchronizacji zakończonej sukcesem.

Lista: 25 pozycji na stronę, „Pokaż więcej”, sortowanie malejąco po `detected_at`,
następnie stabilnie po `ref`. Wybrana karta ma tint i widoczny stan zaznaczenia.
Klik nie uruchamia agenta. Lista na desktopie wybiera pierwszy wynik, jeśli URL
nie wskazuje sprawy; na telefonie nie otwiera automatycznie dialogu.

Szczegół zawiera identyfikatory, tytuł, projekt, priorytet, status i oznaczenie
„Tylko analiza” albo „Naprawa zatwierdzona”. Trzy zakładki:

- Analiza: podsumowanie, fakty ze źródłami, hipotezy, brakujące dane,
  rekomendowany następny krok, wersja, data i model; nie udajemy pewności diagnozy.
- Zgłoszenie: bezpiecznie wyrenderowany tekst Jira, źródło, data, priorytet,
  docelowy Linear, reguła i stan każdego efektu integracji.
- Historia: wykrycie, import, analiza, komentarz, powiadomienia, retry i decyzje;
  zdarzenia UTC prezentowane w lokalnej strefie przeglądarki z pełną datą w tooltipie.

„Zobacz w Jira” i „Zobacz w Linear” to identyczne wizualnie linki typu button,
ten sam rozmiar/variant, ikona external-link, `target=_blank`, `rel=noopener noreferrer`.
Link Linear aktywny dopiero po potwierdzeniu utworzenia. Brak linku: disabled z wyjaśnieniem,
bez `href="#"`. Dla starej pracy tylko Linear: Jira disabled „Brak powiązania Jira”.

Akcje nie mają optymistycznego sukcesu. Pokazać pending, błąd przy akcji i możliwość
ponowienia właściwego kroku. „Przyjmij sprawę” = lokalne `acknowledged_at`, przenosi
z Do decyzji do Przekazane dopiero przy opublikowanej analizie, bez zmiany Jira/Linear.
Przy problemie technicznym najpierw „Ponów [krok]”; samo przyjęcie nie ukrywa awarii.

### 4.5. Kanban i zachowanie responsywne

Cztery kolumny: Wykryte, W analizie, Do decyzji, Przekazane; kolejność stała.
Zwykłe kafelki, bez uchwytów przeciągania. Klik otwiera szczegół w dialogu,
Escape zamyka i przywraca focus. Wszystkie akcje jak w szczególe listy.
Każda kolumna pobiera własną stronę po 25 elementów; osobne „Pokaż więcej” i cursor.
Nagłówek kolumny pokazuje całkowitą liczbę, nawet gdy część kart nie jest załadowana.

- Powyżej 1150 px: cztery kolumny, sidebar 218 px.
- 851–1150 px: dwie kolumny, sidebar 185 px.
- 601–850 px: dwie kolumny, sidebar w wysuwanym panelu pod hamburgerem.
- Do 600 px: jedna kolumna; Lista bez stałego prawego panelu, szczegół w dialogu.
- 390 px: brak poziomego scrolla całej strony, toolbar zawija się, pełne nazwy przycisków.

Nie gubić mobilnej nawigacji przy schowaniu sidebaru. Panel i dialog: focus trap,
Escape, przywrócenie focusu, nazwa dostępności. Etykiety kontrolek nie mogą być
zastępowane placeholderem. Statusy muszą mieć tekst; skeleton/error/empty per sekcja.
Offline: pozostawić ostatnie dane z jawnym ostrzeżeniem i wyłączyć mutacje.
Dark mode i reduced motion podlegają testom, nie są osobnym projektem UI.

### 4.6. Pozostałe ekrany

Automatyzacje: lista reguł z projektem, źródłem, priorytetami, częstotliwością,
włącznikiem, ostatnim sukcesem, następnym terminem i błędem; nie tylko pojedynczy formularz.
Edytor wykorzystuje cztery sekcje makiety: źródło/harmonogram, Linear,
powiadomienia, podgląd działania. Formularze React Hook Form + Yup, walidacja także w backendzie.
Podgląd to suche sprawdzenie bez wiadomości/ticketów/analizy/komentarzy.
Zapis reguły nie aktywuje jej; aktywacja jest osobnym potwierdzonym krokiem.

Integracje: karty stanu oraz edycja parametrów/sekretów. „Sprawdź połączenie”
nie wysyła próbnego SMS/e-mail. Osobne „Wyślij test” wymaga odbiorcy i potwierdzenia kosztu.
Linear jest istniejącym połączeniem per projekt, nie nowym niezależnym magazynem tokenów.

CRUD projektów, workspace, run detail, diagnostyka, 404 i error boundary otrzymują
te same tokeny/typografię/etykiety polskie. Funkcji nie zastępować statycznymi obrazkami.
Zachować dowody, paginowaną historię, logi, wskaźniki tokenów oraz dotychczasowe
semantyki Stop/Retry. Stop nadal jest opisanym w repo soft-stop, nie obietnicą zabicia procesu OS.

## 5. Architektura i odpowiedzialności

```text
Jira Scheduler → CloudClient → Matcher → Intake (transakcja PostgreSQL)
                                          ├─ outbox e-mail / SMS
                                          └─ outbox Linear Todo + blokada
                                                      ↓
                                              AnalysisRunner (read-only)
                                                      ↓
                                         wynik w DB → komentarz w Jira

Cases (projekcja Intake + istniejące WorkRun) → REST + invalidacja Channel → UI A
UI: Rozpocznij naprawę → trwała zgoda → ExecutionGate → istniejący Orchestrator
```

Nowe moduły pod `elixir/lib/symphony_elixir/`:

- `Intake`: transakcje, reguły, sprawy, wersje analiz i decyzje; bez HTTP.
- `Intake.Scheduler`: wyłącznie harmonogram/claim skanów, nie pętla agentów Linear.
- `Intake.Poller`, `Intake.Matcher`: skan i kwalifikacja; czysty matcher testowany osobno.
- `Intake.Outbox`, `Intake.Dispatcher`: trwałe efekty, leasing, retry i odbudowa po restarcie.
- `Intake.LinearBridge`: utworzenie i odnalezienie docelowego zadania.
- `Intake.ExecutionGate`: jedyna reguła zezwalająca/odmawiająca implementacji importu.
- `Intake.AnalysisRunner`, `AnalysisPolicy`, `AnalysisResult`, `CommentRenderer`:
  izolowana analiza, walidacja rezultatu i deterministyczny komentarz.
- `Jira.CloudClient`, `Jira.Adf`: transport i konwersja tekstu ADF, bez logiki workflow.
- `Notifications.{SMTP,Smsapi}`: adaptery efektów; bez harmonogramu i deduplikacji domenowej.
- `Cases`: odczyt i agregacja; nie tworzy pracy, nie przepisuje istniejącej historii.

Wzorzec HTTP: istniejący Req + wstrzykiwane `request_fun`/adaptery testowe.
Efekty uruchamia Task.Supervisor. Nie wykonywać zdalnego HTTP w transakcji DB.
Config runtime przez `SymphonyElixir.Config`/`Config.Schema`, nie rozproszone `System.get_env`.

## 6. Model danych i trwałe niezmienniki

Wszystkie nowe PK/FK UUID, daty `utc_datetime_usec`, enumy jako string z CHECK,
`inserted_at/updated_at`, `lock_version` dla edytowalnych rekordów. Brak hard delete w UI.
Sekrety: `SymphonyElixir.Encrypted.Binary`, `redact: true`, istniejący Vault/CLOAK_KEY.
Nie kopiować sekretów do `config`, JSON API, audit event ani snapshotu reguły.

### 6.1. Tabele

| Tabela                    | Wymagane pola poza PK/timestamps                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `integration_connections` | `kind: jira_cloud/smtp/smsapi`, `name`, `settings: jsonb`, `secret?: encrypted binary`, `secret_version=1`, `enabled=false`, `last_checked_at?`, `health: unchecked/ok/error`, `error_code?`, `lock_version`                                                                                                                                                                                                                                                                                                                                              |
| `automation_rules`        | `project_id`, `jira_connection_id`, `name`, `source_type: board/filter`, `source_id`, `priority_ids: text[]`, `interval_seconds`, `initial_policy`, `linear_team_id`, `linear_project_id`, `linear_todo_state_id`, `linear_hold_label_id`, `email_connection_id?`, `sms_connection_id?`, `email_recipients: text[]`, `sms_recipients: text[]`, `enabled=false`, `config_version=1`, `activated_at?`, `baseline_complete_at?`, `last_started_at?`, `last_success_at?`, `next_poll_at?`, `last_error_code?`, `lease_token?`, `lease_until?`, `lock_version` |
| `jira_observations`       | `jira_connection_id`, `jira_issue_id`, `rule_id`, `first_seen_at`, `last_seen_at`, `last_priority_id?`, `baseline_excluded: boolean`                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `intake_cases`            | `project_id`, `rule_id`, `jira_connection_id`, `jira_issue_id`, `jira_key`, `jira_url`, `title`, `description_text`, `priority_id`, `priority_name`, `jira_updated_at`, `detected_at`, `rule_snapshot: jsonb`, `linear_issue_id` (rezerwowane UUID), `linear_identifier?`, `linear_url?`, `linear_state_name?`, `linear_confirmed_at?`, `analysis_version=1`, `analysis_status`, `acknowledged_at?`, `repair_approved_at?`, `repair_approved_version?`, `lock_version`                                                                                    |
| `intake_analyses`         | `case_id`, `version`, `status: queued/running/succeeded/failed/needs_input`, `input_snapshot: jsonb`, `result: jsonb?`, `model`, `effort`, `started_at?`, `completed_at?`, `token_usage: jsonb?`, `error_code?`, `work_run_id?`                                                                                                                                                                                                                                                                                                                           |
| `integration_deliveries`  | `case_id?`, `connection_id?`, `operation`, `dedupe_key`, `payload: jsonb`, `status`, `attempts=0`, `next_attempt_at`, `lease_token?`, `lease_until?`, `provider_id?`, `first_attempt_at?`, `sent_at?`, `last_error_code?`                                                                                                                                                                                                                                                                                                                                 |
| `intake_events`           | `case_id?`, `rule_id?`, `type`, `payload: jsonb`, `actor: system/operator`, `occurred_at`                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `automation_scans`        | `rule_id`, `rule_config_version`, `mode: baseline/poll/preview`, `status: pending/running/succeeded/failed/cancelled`, `generation` UUID, `started_at?`, `finished_at?`, `match_count=0`, `accepted_count=0`, `error_code?`                                                                                                                                                                                                                                                                                                                               |

Uzupełniające pola: rule ma `activation_status: idle/activating/error`,
`baseline_generation?`; observation ma `generation` skanu bazowego.
Wpis obserwacji wyklucza import tylko wtedy, gdy jego generation jest zatwierdzoną
baseline_generation reguły. Nowy baseline nie usuwa przypadków ani historycznych eventów.
Unikalny częściowy indeks active rule obejmuje `enabled=true OR activation_status='activating'`.
`integration_deliveries` ma `lock_version`; test-send ma case_id=null i unikalny
klucz żądania, aby podwójny klik nie wysłał drugiego testu.

Połączenie Jira powiązane z case ma niezmienny site_url; zmiana instancji wymaga
nowego connection. Analogicznie po pierwszej aktywacji reguły project_id,
jira_connection_id oraz cel Linear są nieedytowalne. Można utworzyć nową regułę,
ale globalna unikalność case nadal obowiązuje; nie przepisuje automatycznie historii.

`intake_cases.analysis_status`: `queued/running/ready/needs_input/failed`.
`integration_deliveries.status`: `pending/running/retry_wait/succeeded/failed/unknown/paused`.
`operation`: `linear_create/email/sms/analysis/jira_comment`; analysis job wskazuje
wersję, wynik trzymamy w analyses. Jira_comment provider_id to comment ID.
Delivery e-mail/SMS powstaje oddzielnie dla każdego odbiorcy, nie dla całej listy.

Snapshot reguły: ID projektu/instancji/źródła, nazwy, priorytety, docelowe ID Linear,
ID połączeń powiadomień, odbiorcy, config_version, czas kwalifikacji.
Zmiana reguły dotyczy przyszłych spraw; zapisane efekty nie zmieniają odbiorców.
Rotacja sekretu korzysta z aktualnego sekretu tego samego połączenia.

Unikalność wymuszana przez PostgreSQL:

- connection: jedna Jira na znormalizowany `settings.site_url` (unikalny indeks wyrażeniowy dla kind Jira).
- observation: `(rule_id, jira_issue_id)`.
- case: `(jira_connection_id, jira_issue_id)`; nie używać klucza OPS-123 jako tożsamości.
- case: globalnie unikalne `linear_issue_id`, rezerwowane przed zdalnym create.
- analysis: `(case_id, version)`.
- delivery: `dedupe_key`, np. `case:<uuid>:email:<sha256-odbiorcy>:detected:v1`,
  `case:<uuid>:linear:v1`, `case:<uuid>:analysis:<n>`, `case:<uuid>:jira-comment:<n>`.

Indexy: rules `(enabled,next_poll_at)`, deliveries `(status,next_attempt_at)`,
cases `(project_id,detected_at,id)`, events `(case_id,occurred_at,id)`.
FK delete restrict dla konfiguracji z historią. Wyłączenie nie kasuje danych.
DB niedostępna: odmowa nowych efektów i implementacji importów, nigdy fallback w pamięci.

### 6.2. Leasing i retry

Scheduler budzi się co 5 s; claim przez krótką transakcję i `FOR UPDATE SKIP LOCKED`.
Maksymalnie jeden aktywny skan reguły i dwa skany globalnie; lease 120 s,
heartbeat 30 s. Token lease zmienia się przy każdym claim.
Wyniki starego właściciela po utracie lease są odrzucane przez compare-and-swap.

Dispatcher co 1 s; maksymalnie cztery efekty I/O i jedna analiza jednocześnie.
Lease efektu I/O 120 s, timeout requestu 30 s; analiza lease 120 s z heartbeat 30 s
i twardym limitem całej próby 10 min. Utrata lease analizy przerywa próbę,
nie publikuje jej późnego wyniku. Retry wyłącznie przez rekord delivery.

Bezpiecznie ponawialne błędy transportu: 5 prób łącznie, odstępy 30/120/600/1800 s
z dodatnim jitter do 10%. `Retry-After` może tylko wydłużyć termin; obsłużyć sekundy
oraz datę HTTP. 401/403 i walidacja 4xx → failed z instrukcją operatora.
429 → retry_wait i widoczny termin. Awaria jednej reguły/kanału nie blokuje pozostałych.
Retry w Req wyłączyć dla efektów, aby nie powstała druga niewidoczna pętla.

Wygaśnięty lease operacji mogącej coś wysłać oznacza `unknown`, nie automatyczny
powrót do pending. Linear może się uzgodnić po UUID; komentarz po markerze;
SMTP nie ma gwarancji idempotencji. Szczegóły §8 i §10 mają pierwszeństwo nad ogólnym retry.

Ręczny retry failed dopuszcza jedną dodatkową próbę; nie zeruje attempts ani historii.
Ręczny retry unknown wymaga `confirm_duplicate_risk=true` i ponownego odczytu stanu
zewnętrznego, jeśli adapter to umożliwia. succeeded/running → 409; paused wymaga
uprzedniego włączenia zależności. Wyłączone connection nie jest claimowane,
delivery dostaje paused, a po włączeniu wraca do poprzedniego bezpiecznego stanu.
Przechować go w `payload.resume_status`; unknown nigdy nie wraca automatycznie do pending.

## 7. Reguły i odpytywanie Jira Cloud

### 7.1. Konfiguracja

Interwał: liczba całkowita 60–86400 s, domyślnie 300; UI liczba + sekundy/minuty/godziny,
szybkie wartości 1/5/10/15/30/60 min. Priorytety wybierane po ID z Jira, minimum jeden,
nie hardkodować nazw Critical/Highest ani zakładać, że ID oznacza kolejność.
Pierwszy zapis: disabled. Jedno źródło na regułę: board ID albo saved filter ID;
brak dowolnego pola JQL w pierwszym wydaniu.

`initial_policy=new_matches_only` domyślnie: przed aktywacją pełny skan bazowy,
dopasowane istniejące zgłoszenia zapisane jako baseline_excluded bez efektów.
`initial_policy=include_existing`: jawnie zaznaczona opcja importu istniejących,
podgląd liczby i potwierdzenie przed aktywacją. Po pierwszej aktywacji polityka nieedytowalna.
Baseline obserwuje tylko zgłoszenia pasujące; stare niskopriorytetowe po podniesieniu
priorytetu mają zostać przyjęte. Częściowy/nieudany baseline nie aktywuje reguły.
Obsłużyć baseline transakcyjnie przez identyfikator generacji skanu, nie połowiczny zapis.

Jedna aktywna reguła na `(jira_connection_id,source_type,source_id)`.
Różne źródła mogą się nakładać: zwycięża pierwsza kwalifikacja zapisana w DB,
kolejne rejestrują `already_linked` i pokazują link do sprawy; nie zmieniają celu Linear.
Podgląd i aktywacja ostrzegają o znalezionych kolizjach między projektami.

Do aktywacji wymagane: działająca Jira, poprawne źródło i priorytety, docelowy
projekt/zespół Linear, stan o dokładnej nazwie Todo w tym zespole, etykieta ochronna,
działający profil analizy, wszystkie zaznaczone kanały z odbiorcami.
Brak Todo → 422, nie utworzenie w Backlog. Oba kanały mogą być wyłączone świadomie.

### 7.2. Transport i algorytm

Jira connection settings: `site_url`, `auth_mode=classic|scoped`, `account_email`,
`cloud_id` wymagane dla scoped. API token jest jedynym sekretem, nie hasłem konta.
Classic używa site URL; scoped używa `https://api.atlassian.com/ex/jira/<cloud_id>`.
Linki dla ludzi zawsze `site_url/browse/<key>`. Zakaz automatycznego fallbacku auth.
To rozróżnienie wynika z [dokumentacji tokenów Atlassian](https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account).

Pobranie board configuration daje filter ID; query reguły to
`filter = <id> AND priority in (<id-list>) AND statusCategory != Done ORDER BY key ASC`.
ID muszą przejść walidację; wartości cytować/escapować, bez wstawiania tekstu użytkownika.
Board oznacza zapisany filtr tablicy, nie quick filter, sprint ani bieżący widok przeglądarki.
Reguła typu filter działa bez Jira Software board API.

Używać `POST /rest/api/3/search/jql`, stron 100 i `nextPageToken`; nie starego `/search`.
Żądane pola: summary, description, priority, status, created, updated, project.
Po każdej stronie trwale kwalifikować zgłoszenia w transakcjach; sukces całego skanu
dopiero po ostatniej stronie. Po awarii następny skan od początku; unikalność zapobiega duplikatom.
Paginacja zgodna z [Jira enhanced search](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/).

Każdy skan odczytuje pełny bieżący wynik, nie tylko `created > last_poll`.
Dzięki temu wykrywa awans priorytetu, zmianę filtra i opóźnione indeksowanie.
Zmiana pasujący → niepasujący → pasujący nie tworzy drugiej sprawy.
Zmiana ID źródła lub zestawu priorytetów wyłącza regułę i wymaga nowego baseline;
już utworzone case pozostają. Zmiana samego interwału nie resetuje deduplikacji.
Po pauzie: wznowienie bez nowego baseline, zaległe pierwsze dopasowania są przyjmowane.

Polling nie gwarantuje wykrycia priorytetu, który pojawił się i zniknął między dwoma
odczytami. Pokazać tę informację w pomocy reguły; nie obiecywać audytu changelogów.
Nie pobierać załączników ani linkowanych stron. Opis ADF zamienić na plain text,
zachowując akapity/listy/bloki kodu; nie renderować dowolnego HTML.
Limit opisu 100 KiB UTF-8 z oznaczeniem skrócenia; brak opisu nie odrzuca sprawy.

Skan ograniczony do 10 min/10000 wyników. Przekroczenie → `scan_limit_exceeded`,
last_success nie zmienia się, UI prosi o zawężenie filtra. Nigdy udawany pełny sukces.
`next_poll_at = zakończenie próby + interval`, bez równoległych zaległych ticków.
Ręczne „Sprawdź teraz” używa tej samej blokady; 202 albo 409 `scan_in_progress`.
Pauza zatrzymuje nowe skany; już przyjęte sprawy kończą efekty, chyba że operator
wyłączy konkretne połączenie lub globalny kill switch opisany w §13.

## 8. Linear Todo bez przypadkowej implementacji

### 8.1. Utworzenie i idempotencja

W transakcji kwalifikacji powstają case, rezerwowane UUID `linear_issue_id`,
analiza v1 queued, events i efekty linear_create/email/sms. Analiza czeka
na potwierdzenie Linear, powiadomienia nie czekają. Awaria Linear jest widoczna w Do decyzji.

`LinearBridge` używa tokenu docelowego projektu (`tracker_secret`, z istniejącym
udokumentowanym fallbackiem globalnym), nigdy tokenu innego projektu.
Wywołuje istniejący `Linear.Client.graphql/3` z jawnym `token` i `request_fun`.
Rozszerzyć transport o timeout/retry kontrolowane przez caller, bez psucia istniejących wywołań.
HTTP 200 z GraphQL `errors` nie jest sukcesem; wymagać `success=true` i pasującego UUID.

Mutation `issueCreate(input: IssueCreateInput!)`:

- `id`: rezerwowane UUID; `teamId`, `projectId`, `stateId`: zwalidowane ID reguły.
- `title`: `[<jira_key>] <summary>`, limit 255 znaków z bezpiecznym skróceniem Unicode.
- `description`: link Jira, ID sprawy Harmony, priorytet, informacja „Tylko analiza;
  naprawa wymaga zgody w Harmony”, opis źródłowy i link do `/cases/jira_<uuid>`.
- `labelIds`: wymagane ID etykiety `harmony:analysis-only` zwalidowane przed aktywacją.
- Nie ustawiać osoby odpowiedzialnej ani daty bez decyzji operatora.
- `priority` pomijać: Jira ma własne priorytety, nie wprowadzać pozornej mapy 1:1.

Możliwość podania `id` jest częścią
[schematu Linear](https://raw.githubusercontent.com/linear/linear/master/packages/sdk/src/schema.graphql).
Preflight implementacji ma test kontraktowy tego pola; jeśli API go nie obsługuje,
etap jest zablokowany, nie zastępować go wyszukiwaniem po tytule.
Po timeout: `issue(id: reserved_uuid)`, walidacja projektu i markerów; jeżeli istnieje,
zapisać link i sukces. Jeśli pewne not found, ponowić create z tym samym UUID.
Nigdy nie generować nowego UUID w retry. 403/niejednoznaczny odczyt → unknown.

Stan Todo trzeba wskazać jawnie; bez `stateId` API może wybrać inny stan.
[Dokumentacja tworzenia zadań Linear](https://linear.app/developers/graphql).
Etykieta nie jest tworzona automatycznie w pickerze. Aktywacja może ją utworzyć
po jawnym potwierdzeniu „Utwórz etykietę ochronną w Linear”, potem utrwala ID.

### 8.2. ExecutionGate — wymaganie krytyczne

Guard ma być wywołany przy pobraniu LinearIssueSource oraz bezpośrednio przed
każdym startem implementacji w orchestratorze, w tym retry, continuation po
zakończeniu próby i odzyskiwaniu po restarcie. Nie wystarczy filtr pierwszego pollu.

Algorytm `authorize_implementation(issue, project_id)`:

1. Szukaj case po `linear_issue_id` (również jeszcze niepotwierdzonym).
2. Jeżeli case istnieje: wymaga zgodnego project_id i trwałej zgody dla bieżącej
   analysis_version; bez niej `deny: analysis_only`, bez startu workspace/runnera.
3. Jeżeli case nie istnieje, ale issue ma etykietę ochronną albo marker Harmony
   w opisie: odmowa `unlinked_managed_issue`, nie traktować jako zwykłego Todo.
4. Jeżeli brak case i markerów: dotychczasowa polityka zwykłych zadań Linear.
5. Błąd DB lub niekompletny odczyt wymaganych pól: fail closed, nie zakładać braku case.

DB mapping jest główną ochroną; etykieta i marker zabezpieczają wyścig oraz
częściowe odtworzenie danych. Usunięcie etykiety nie znosi ochrony istniejącego case.
Nie modyfikować globalnej listy active_states; zwykłe Todo innych projektów działają dalej.
Nowe per-project pobieranie Linear musi faktycznie filtrować po projekcie i używać
jego tokenu. Obecne przekazanie `project_id` do WorkRun nie wystarcza, ponieważ
domyślny fetcher LinearIssueSource odczytuje globalną konfigurację.

„Rozpocznij naprawę” dostępne po poprawnej analizie ready, potwierdzonym Linear
i opublikowanym komentarzu. Dialog pokazuje projekt, repozytorium, Linear i wyjaśnia
możliwe zmiany kodu/PR. Potwierdzenie z `expected_version` zapisuje zgodę i zdarzenie
w jednej transakcji, a następnie prosi istniejący orchestrator o refresh.
Powtórzone kliknięcie zwraca istniejącą zgodę, nie drugi przebieg.
Nie zmienia Jira statusu; nie tworzy drugiego Linear; pozostawia etykietę jako marker pochodzenia.
Zgoda nie omija innych warunków dispatch (capacity, assignee, aktywny status, repo policy).
UI pokazuje „Naprawa zatwierdzona — oczekuje na uruchomienie”, nie od razu „W toku”.

## 9. Analiza tylko do odczytu

### 9.1. Granica wykonania

Osobny `AnalysisRunner`, a nie `AgentRunner.run/3` z innym promptem.
Nie wywołuje hooków `after_create/before_run/after_run`, nie ładuje projektowego
WORKFLOW jako instrukcji implementacji, nie publikuje komentarzy przez narzędzia modelu.
Publikację realizuje deterministyczny backend po walidacji wyniku.
Analiza ma własny WorkRun `type=jira_analysis` dla historii/tokenów, ale nie jest
kandydatem zwykłego `choose_work_runs`; zarządza nią Intake.Dispatcher.

Profil `analysis` w Config.Schema:

| Pole               | Kontrakt                                                                    |
| ------------------ | --------------------------------------------------------------------------- |
| `enabled`          | false do zakończenia testu izolacji                                         |
| `model`            | wymagany jawnie przy włączeniu; wybrany przez operatora z dostępnych modeli |
| `effort`           | `medium`; zapisywany jawnie w sesji i analizie                              |
| `max_concurrent`   | 1, zakres 1–4; osobna pula widoczna w diagnostyce                           |
| `timeout_ms`       | 600000, zakres 60000–900000, twardy czas ścienny                            |
| `max_turns`        | stałe 1; bez kontynuowania dlatego, że Linear pozostaje Todo                |
| `max_result_bytes` | 32768                                                                       |

Nie dobierać automatycznie „najtańszego” modelu ani nie fallbackować na droższy.
Brak modelu/uprawnień → reguła nieaktywna z konkretnym komunikatem.
To parametr wdrożenia, nie swoboda modelu wykonującego plan.

Reuse `Codex.AppServer` wymaga nazwanego profilu uprawnień `analysis_ro` w prywatnym
`CODEX_HOME/config.toml`. Profil nie dziedziczy po `:read-only`: daje `:minimal = read`,
tylko kanonicznemu plikowi wykonywalnemu Codex niezbędny odczyt i `"." = read` pod
`:workspace_roots`; sieć ma `enabled = false`. W konfiguracji nie wolno ustawiać
`sandbox_mode` ani `sandbox_workspace_write`, bo starsza konfiguracja sandboxa może
wyłączyć named profiles. Klient App Server wybiera ten sam profil przez `permissions`
w `thread/start` i `turn/start`, a przez `permissionProfile` w `command/exec`; nie wysyła
równocześnie starych pól `sandbox` ani `sandboxPolicy`. Nieznany profil lub błąd protokołu
oznacza błąd startu, bez przejścia na słabszą politykę.

Polityka akceptacji pozostaje `on-request`; `approval_policy = never` nie oznacza
automatycznej akceptacji. Profil analizy ma puste `dynamicTools`, a executor odmawia
wywołania dowolnego dynamicznego narzędzia. Wyłączyć odziedziczone MCP, pluginy,
umiejętności i instrukcje z katalogów domowych oraz repo; prywatna konfiguracja zawiera
wyłącznie uwierzytelnienie potrzebne do modelu. Proces app-server może otrzymać
`OPENAI_API_KEY`/`CODEX_API_KEY` lub prywatny `auth.json`; te dane nie trafiają do
środowiska poleceń shell. `CLOAK_KEY`, tokeny Jira/Linear/SMTP/SMS/forge i credentials
bazy są usuwane przed startem app-servera. Proces Codex dla tej ścieżki uruchamia się
bez login shell odczytującego profile użytkownika.

Profile uprawnień Codex są beta. Dokładny kształt `permissions`, `permissionProfile`
i lokalnej konfiguracji weryfikować względem zainstalowanego CLI oraz jego wygenerowanego
schematu; test T11 uruchomiono z `codex-cli 0.155.1`, a testy raportują faktyczną wersję.
Źródła: [App Server](https://developers.openai.com/codex/app-server)
i [profile uprawnień](https://developers.openai.com/codex/permissions). Wstępny test
rzeczywistego CLI bez turnu/modelu potwierdza `thread/start`, `command/exec`, odczyt
workspace, odmowę dostępu do syntetycznego auth i operatorowej konfiguracji, brak zapisu,
brak sieci oraz odrzucenie konfliktu `permissionProfile`/`sandboxPolicy`. Test sprawdza
oddzielnie env procesu app-server i env poleceń: syntetyczne API keys są dostępne wyłącznie
procesowi serwera; tokeny integracji są usunięte. Polecenia sprawdzają env i czytelne
`/proc/*/environ`; nie widzą canary. Syntetyczny auth pozostaje niedostępny także przez
`/proc/*/root` i deskryptory `/proc/*/fd`.
W workspace znajduje się też
syntetyczny `.codex/config.toml` proszący o `sandbox_mode = "danger-full-access"` i próbujący
nadpisać `analysis_ro` przez `:root = "write"` oraz `network.enabled = true`; próby
create/edit/delete i loopback nadal są blokowane przy jawnym `analysis_ro`. Nie sprawdza zachowania
modelu w turnie. Pełny test wykonania turnu, runnera, timeoutu, późnego wyniku, hooków
i instrukcji pozostaje warunkiem T13/T29 przed włączeniem `analysis.enabled`.

Przed włączeniem konieczny rzeczywisty test braku zapisu, eskalacji i dostępu do
sekretów; sam prompt „nie zmieniaj plików” nie spełnia wymagania.

### 9.2. Kontekst i wynik

`AnalysisContext` przygotowuje osobny katalog pod `workspace.root/intake/<case-id>/<version>`.
Nie używa źródłowego checkoutu Harmony jako cwd. Pobiera snapshot kodu skonfigurowanego
repozytorium projektu przy konkretnym SHA domyślnej gałęzi przez backend forge.
Snapshot: archiwum bez `.git`, bez wykonywania skryptów/install/build, bez podmodułów.
Sprawdzić ścieżki, odrzucić traversal, symlinki/hardlinki oraz archiwum >100 MiB
po rozpakowaniu lub >20000 plików. Zapisać repo/SHA w input_snapshot.
GitHub/GitLab pozostają wspierane; pobranie używa aktualnych poświadczeń projektu
po stronie backendu, nie udostępnia ich analizatorowi.
Kontrakt archive: GitHub `/repos/{owner}/{repo}/tarball/{sha}`, GitLab
`/projects/{url-encoded-full-path}/repository/archive.tar.gz?sha=<sha>`;
bez numerów projektu GitLab. Źródła: [GitHub archives](https://docs.github.com/en/rest/repos/contents#download-a-repository-archive-tar)
i [GitLab archives](https://docs.gitlab.com/api/repositories/#get-file-archive).
Nie wykonywać instrukcji z AGENTS/CLAUDE/WORKFLOW w snapshocie; profil runtime
wyłącza ich automatyczne ładowanie. Odczyt shell ograniczony do snapshotu i
niezbędnych plików systemowych; ruch sieciowy narzędzi modelu zablokowany.

Jeśli repo nieosiągalne/za duże: wykonać analizę samego zgłoszenia z jawnym
`context_scope=issue_only` i brakiem potwierdzonych twierdzeń o kodzie.
Kontekst zawiera opis zgłoszenia, priorytet, nazwę projektu, regułę, linki oraz snapshot.
Nie pobierać arbitralnych URL-i z opisu. Instrukcje wewnątrz ticketu/repo traktować
jako niezaufane dane; nie wykonują zmian trybu, adresatów ani źródeł.

Wynik JSON, wszystkie pola wymagane, `additionalProperties=false`:

```json
{
  "summary": "Krótki opis ustaleń",
  "facts": [{ "text": "Zaobserwowany fakt", "source": "jira:OPS-142" }],
  "hypotheses": [
    {
      "text": "Możliwa przyczyna",
      "confidence": "low",
      "evidence": ["jira:OPS-142"]
    }
  ],
  "missing_data": ["Log błędu z czasem wystąpienia"],
  "next_steps": ["Sprawdzić czas wykonania zapytania"],
  "needs_input": true,
  "context_scope": "issue_only"
}
```

`confidence=low|medium|high`; `context_scope=issue_only|issue_and_repository`.
Summary max 2000 znaków, tablice max 20 elementów, tekst elementu max 1000,
source tylko Jira key lub istniejąca ścieżka snapshotu z opcjonalną linią.
Backend odrzuca błędny JSON, nieistniejące źródła, przekroczone limity i HTML.
Nie wyciąga JSON regexem z dowolnego tekstu ani nie publikuje surowego stdout.
Niepełny wynik jest failed, `needs_input=true` to poprawny wynik wymagający danych.
Brak kodu w kontekście nie pozwala na `issue_and_repository` nawet gdy model tak zwróci.

Próba analizy: maksymalnie 2 starty modelu na wersję (pierwszy + jedna próba po
technicznym niepowodzeniu), nigdy retry samej publikacji przez ponowne wywołanie modelu.
Ręczne „Przeanalizuj ponownie” tworzy vN+1 z nowym input_snapshot po potwierdzeniu kosztu,
tylko przed zatwierdzeniem naprawy; stare wyniki pozostają w historii.
Reanaliza usuwa acknowledged_at, a wynik wymaga ponownego przyjęcia.

### 9.3. Komentarz Jira

Po zapisaniu wyniku powstaje delivery `jira_comment:<version>`.
Body w ADF: nagłówek `Analiza Harmony — <Jira key>`, podsumowanie, fakty ze źródłami,
hipotezy (oznaczone jako hipotezy), brakujące dane, kolejne kroki, link Linear,
data/SHA kontekstu, „Nie wykonano zmian w kodzie”. Bez logów, tokenów i sekretów.
Na końcu widoczny marker `Harmony analysis <case_uuid>/v<version>`; ta sama wartość
w comment property `harmony.analysis`. ADF generowany z bezpiecznych node'ów tekstowych.
API komentarzy opisuje [Jira Cloud comments](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-comments/).

POST tylko raz przy znanym braku wyniku. Po timeout/utracie lease: odczyt komentarzy
ze wszystkich stron i szukanie własnego markera. Znaleziony → zapisać comment ID.
Brak po niejednoznacznym POST → unknown i ręczna decyzja, nie ślepy drugi POST.
Nie udawać exactly-once tam, gdzie Jira nie dostarcza atomowego klucza idempotencji.
Reanaliza publikuje nowy komentarz z nową wersją; nie edytuje cudzych komentarzy.
403 dodawania komentarza nie usuwa wyniku analizy; karta ma „Analiza gotowa; błąd publikacji”.

## 10. Powiadomienia SMTP i SMSAPI

### 10.1. Kanały i treść

Wyłącznie alert pierwszego wykrycia, nie po każdym pollu. Nie dodawać cyklicznych
przypomnień, maili marketingowych ani SMS po każdej zmianie agenta.
Reguła zawiera osobne listy adresatów, maksymalnie 10 e-maili i 10 numerów.
Normalizacja i deduplikacja: trim, domena maila lower-case, telefon E.164.
SMTP wysyła jedną wiadomość do jednego odbiorcy, bez ujawniania innych adresów.

E-mail: temat `[Harmony] <priority> · <jira_key> · <project>`; body plain text
oraz bezpieczny HTML, krótki tytuł, link Jira i Harmony, czas wykrycia,
„Analiza została zakolejkowana. Naprawa nie została uruchomiona”.
Nie zawiera pełnego opisu ani wyniku analizy. Link Linear nie jest wymagany w alercie,
ponieważ może jeszcze nie istnieć; szczegół Harmony pokaże go po utworzeniu.

SMS: `Harmony: <jira_key>, <priority>. Nowa sprawa: <case_url>`.
Limit 134 jednostek UTF-16 (maksymalnie dwa segmenty Unicode); jeśli link/identyfikator
nie mieści się, przerwać walidację konfiguracji zamiast ucinać URL.
Nie używać publicznych skracaczy ani tytułu zgłoszenia. W UI wskazać możliwość dwóch
płatnych segmentów. Odbiorca i publiczny URL Harmony są sprawdzane przed aktywacją.

### 10.2. SMTP

Settings: host, port (domyślnie 587), tls_mode `starttls|tls`, username,
from_email, from_name (Harmony), message_id_domain. Secret: hasło SMTP.
TLS i walidacja certyfikatów obowiązkowe poza syntetycznymi testami lokalnymi.
Adapter przez Swoosh + gen_smtp; wersje przypiąć w mix.lock w dedykowanym zadaniu,
nie pisać własnego parsera SMTP. [Adapter SMTP Swoosh](https://hexdocs.pm/swoosh/Swoosh.Adapters.SMTP.html).

Stabilny Message-ID na delivery, np. `<harmony.<delivery_uuid>@<configured-domain>>`.
Sukces = SMTP zaakceptował wiadomość, nie dowód doręczenia użytkownikowi.
Rozróżnić odrzucenie przed DATA od niepewności po przekazaniu DATA. Jeśli adapter
nie potrafi udowodnić, że nie wysłał, timeout to unknown; zero automatycznych resendów.
Ręczne ponowienie unknown wymaga ostrzeżenia o możliwej podwójnej wiadomości.

### 10.3. SMSAPI

Stały endpoint `https://api.smsapi.pl/sms.do`, POST form, Authorization Bearer.
Pola: `to`, `from`, `message`, `format=json`, `encoding=utf-8`, `idx=<delivery_uuid>`,
`check_idx=1`. Nie umieszczać tokenu ani numeru w URL/logach.
Sekret: token, settings: zatwierdzona nazwa nadawcy; bez automatycznego failover domeny.
HTTP 200 może zawierać błąd dostawcy; walidować body i status każdego odbiorcy.
`provider_id` zapisać po przyjęciu, status UI „Przyjęte przez SMSAPI”, nie „Doręczone”.

SMSAPI dokumentuje ochronę idx w ograniczonym oknie, a opis kodu 53 i opis
parametru podają różne długości tego okna. Nie opierać gwarancji na większej wartości:
ponawianie niepewnej wysyłki automatycznie jest wyłączone; zawsze ten sam idx,
kod 53 = już przyjęte, bez nowego SMS. [Dokumentacja SMSAPI](https://www.smsapi.pl/docs/).
Nie dodawać callbacków doręczenia do pierwszego wydania.

### 10.4. Testy i ograniczenie wysyłki

Zwykłe testy używają stubów; SMTP integration używa tymczasowego lokalnego Mailpit.
Sąsiedni projekt ma tę konwencję w
`../portfel-projektow/backend/tests/Departments.IntegrationTests/MailpitOutboxE2ETests.cs:11`;
nie przenosić stamtąd stosu ani stałych portów. Testy wybierają wolny port.
Prawdziwy SMS/mail tylko w manualnym gate na zatwierdzony adres/numer i za zgodą operatora.

Limit aplikacji: 60 e-maili/h i 20 SMS/h na połączenie, transakcyjnie w DB;
przekroczenie oznacza retry_wait do nowego okna, nie ciche porzucenie.
Nie ma automatycznych testów wysyłki po zapisie konfiguracji.

## 11. Kontrakty REST, projekcji i aktualizacji UI

### 11.1. Wspólne reguły

Prefix `/api/v1`. Nowe kontrolery przed catch-all `/:issue_identifier`.
Błędy: `{"error":{"code":"...","message":"...","fields":{}}}`.
Walidacja 422, brak 404, konflikt wersji/stanu 409, niedostępność zależności 503,
błędne query/cursor 400, zła metoda 405. Żadnych surowych body dostawcy w API.
Mutacje wymagają JSON, same-origin Origin, tokenu CSRF z sesji; nie poszerzać CORS.
Browser API nie może przyjąć cross-origin POST wydającego pieniądze.
Bootstrap SPA pobiera `GET /api/v1/csrf` z credentials same-origin. Kontroler
wykonuje fetch_session i get_csrf_token, zwraca `{ "csrf_token": "..." }`
oraz Cache-Control no-store. Token pozostaje tylko w pamięci api.ts i trafia do
X-CSRF-Token każdej nowej mutacji. Brak/niepoprawny token lub Origin → 403,
bez wykonania akcji. Po 403 odświeżyć token i poprosić o ponowienie przez człowieka;
nie ponawiać automatycznie mutacji. Użyć istniejącego Plug.Session i losowego
secret_key_base generowanego przez HttpServer; nie wstrzykiwać tokenu w statyczny index.html.
Nie zmieniać webhooków forge na sesyjne ani nie uznawać CSRF za uwierzytelnianie.
Wdrożenie pozostaje za zaufaną siecią/proxy; nie publikować API bez kontroli dostępu.

### 11.2. Endpointy

| Metoda i ścieżka                        | Body/query                                                    | Odpowiedź                                                         |
| --------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------- |
| GET `/csrf`                             | brak                                                          | csrf_token; no-store, sesja same-origin                           |
| GET `/cases`                            | project?, filter?, q?, column?, cursor?, page_size=25 (1–100) | items CaseSummary, meta next_cursor/total, counts, project_counts |
| GET `/cases/:ref`                       | ref `jira_<uuid>` albo `run_<uuid>`                           | case, analysis?, links, deliveries, actions, version              |
| GET `/cases/:ref/events`                | cursor?, page_size=50                                         | items, meta.next_cursor                                           |
| POST `/cases/:ref/acknowledge`          | expected_version                                              | case, version; tylko Jira case                                    |
| POST `/cases/:ref/approve-repair`       | expected_version, analysis_version, confirmed=true            | status approved, case; idempotentne                               |
| POST `/cases/:ref/reanalyze`            | expected_version, confirmed=true                              | 202 analysis_version                                              |
| POST `/deliveries/:id/retry`            | expected_status, confirm_duplicate_risk=false                 | 202 delivery; nie retry succeeded                                 |
| GET/POST `/automations`                 | list / RuleInput                                              | rules / 201 rule                                                  |
| GET/PATCH `/automations/:id`            | version przy PATCH                                            | rule; nie aktywuje automatycznie                                  |
| POST `/automations/:id/preview`         | brak; używa zapisanej wersji                                  | sample max 20, match_count, truncated, warnings; zero efektów     |
| POST `/automations/:id/activate`        | version, confirmed=true                                       | 202 activating; enabled dopiero po poprawnym baseline             |
| POST `/automations/:id/pause`           | version                                                       | rule disabled                                                     |
| POST `/automations/:id/check`           | brak                                                          | 202 scan_id albo 409                                              |
| POST `/automations/check`               | project?                                                      | 202 accepted_rule_ids, skipped z kodem powodu                     |
| GET/POST `/integrations`                | list / ConnectionInput                                        | connections / 201 connection                                      |
| GET/PATCH `/integrations/:id`           | version, secret? albo clear_secret=true                       | connection; secret_state set/unset, nigdy wartość                 |
| POST `/integrations/:id/test`           | brak                                                          | health, checked_at, error_code?; bez wysyłki                      |
| POST `/integrations/:id/test-send`      | recipient, confirmed=true                                     | 202 test_delivery; tylko SMTP/SMSAPI                              |
| GET `/integrations/:id/jira/boards`     | q?, cursor?                                                   | items id/name, meta.next_cursor                                   |
| GET `/integrations/:id/jira/filters`    | q?, cursor?                                                   | items id/name, meta.next_cursor                                   |
| GET `/integrations/:id/jira/priorities` | brak                                                          | items id/name                                                     |
| GET `/projects/:id/linear-options`      | brak                                                          | teams/projects/states/hold_label; jawne ID                        |
| POST `/projects/:id/linear-hold-label`  | team_id, confirmed=true                                       | label_id; re-use istniejącej nazwy                                |

RuleInput zawiera edytowalne pola automation_rules z §6.1, poza metadanymi,
lease/timestamps i enabled. Patch jest częściowy, whitelist pól, optimistic lock.
Listy `/automations` i `/integrations` mają cursor/page_size=25, max100.
Pickery paginowane; brak cichego obcięcia do 200 bez możliwości następnej strony.
Test connection korzysta z odczytu tożsamości/uprawnień; SMTP EHLO/TLS/AUTH bez DATA,
SMSAPI odczyt konta/punktów, nigdy próbny sms.do bez świadomego test-send.
test-send wymaga dodatkowo `Idempotency-Key` UUID z formularza, ten sam aż do
rozstrzygnięcia próby. Błędny/brakujący klucz → 422.
Na pozostałych mutacjach version jest integer >=1; expected_version dotyczy case,
version dotyczy config. Te dwa nazewnictwa są stałe w kontrakcie, bez aliasów.

Przykład RuleInput (UUID są syntetyczne):

```json
{
  "name": "Pilne sprawy portalu",
  "project_id": "11111111-1111-4111-8111-111111111111",
  "jira_connection_id": "22222222-2222-4222-8222-222222222222",
  "source_type": "board",
  "source_id": "42",
  "priority_ids": ["1", "2"],
  "interval_seconds": 300,
  "initial_policy": "new_matches_only",
  "linear_team_id": "33333333-3333-4333-8333-333333333333",
  "linear_project_id": "44444444-4444-4444-8444-444444444444",
  "linear_todo_state_id": "55555555-5555-4555-8555-555555555555",
  "linear_hold_label_id": "66666666-6666-4666-8666-666666666666",
  "email_connection_id": null,
  "sms_connection_id": null,
  "email_recipients": [],
  "sms_recipients": []
}
```

Nazwa reguły/połączenia 1–100 znaków; source_id i priority_id niepuste ciągi cyfr;
priority_ids max100 bez duplikatów. Kanał jest włączony, gdy connection_id nie jest
null; wtedy lista odbiorców niepusta. Przy null lista musi być pusta.
Case detail `actions` to obiekt kluczy `acknowledge/reanalyze/approve_repair`,
każdy `{allowed:boolean, reason:string|null}`. Delivery ma własne `retry_allowed`
i `duplicate_risk`. reason jest kodem tłumaczonym przez UI, nie surowym wyjątkiem.
List counts: `{all, decision, analysis, done, detected}` jako nieujemne integer;
project_counts: lista `{project_id,total}`. Detail analysis=null przed wynikiem.

### 11.3. CaseSummary i unifikacja istniejących przebiegów

```ts
type CaseColumn = "detected" | "analyzing" | "decision" | "handed_off";
type CaseSummary = {
  ref: string;
  kind: "jira_intake" | "agent_work";
  project: {
    id: string;
    slug: string;
    name: string;
    color: "purple" | "gold" | "teal";
  };
  title: string;
  jira: { key: string; url: string } | null;
  linear: { identifier: string; url: string } | null;
  priority: {
    id: string | null;
    label: string;
    tone: "critical" | "high" | "normal";
  };
  column: CaseColumn;
  status_label: string;
  execution_mode: "analysis_only" | "repair_approved" | "existing_workflow";
  detected_at: string;
  updated_at: string;
  attention: { code: string; message: string } | null;
};
```

Jira: tone critical tylko dla najwyższego priorytetu według kolejności odpowiedzi
Jira, high dla następnego, reszta normal; ID i nazwa zawsze oryginalne. Gdy kolejność
niedostępna, wszystkie normal — nie zgadywać z nazwy. Walidacja odpowiedzi API
powinna jawnie udostępnić ranking priorytetów lub ten brak.

`Cases` łączy intake_cases i istniejące work_runs przez odczyt, bez podwójnego
zapisywania historii. Dla zwykłych WorkRun wybrać najnowszy rekord na
`(project_id, coalesce(linear_issue_id,dedupe_key,id))`.
Ukryć z tej drugiej gałęzi rekordy powiązane z intake case, aby jedna sprawa
nie występowała drugi raz po rozpoczęciu naprawy. `jira_analysis` też nie jest osobną kartą.
Run bez Linear nadal widoczny jako agent_work, z linkiem forge w szczególe.
Priorytet legacy Linear: 1 critical, 2 high, pozostałe normal, null „Brak priorytetu”.
Tytuł legacy: payload.title, następnie payload.issue.title, następnie identyfikator
Linear lub `<type> · <skrócone run UUID>`; nigdy losowy przykładowy tytuł.
detected_at dla agent_work = inserted_at WorkRun. UUID w coalesce rzutować do text.

| Stan                                                                   | Kolumna                                           |
| ---------------------------------------------------------------------- | ------------------------------------------------- |
| Jira queued / czekanie na utworzenie Linear                            | Wykryte                                           |
| Jira running                                                           | W analizie                                        |
| Jira ready lub needs_input, nieprzyjęta                                | Do decyzji                                        |
| Dowolny Jira failed/unknown lub wymagany efekt w retry_wait            | Do decyzji, błąd nie znika po acknowledge         |
| Jira przyjęta + komentarz opublikowany, bez problemów                  | Przekazane                                        |
| Jira naprawa zatwierdzona, oczekuje na dispatch                        | Wykryte                                           |
| Powiązana implementacja running                                        | W analizie, tekst „Naprawa w toku”, nie „Analiza” |
| Istniejąca praca queued/retrying bez błędu                             | Wykryte                                           |
| Istniejąca praca running                                               | W analizie, tekst „Praca agenta”                  |
| Istniejąca praca blocked/failed/retrying z błędem/stopped/human_review | Do decyzji                                        |
| Istniejąca praca completed/succeeded/handed_off/cancelled              | Przekazane                                        |
| Nieznany status historyczny                                            | Do decyzji z dosłownym statusem, nie ukrywać      |

Pierwszeństwo projekcji Jira: awaria required delivery/analizy → decision;
następnie istniejąca zatwierdzona naprawa → mapping najnowszego implementation run
jak legacy (gdy brak run → detected); następnie analiza running → analyzing;
queued → detected; ready/needs_input → decision, chyba że przyjęto i opublikowano.
Za required uważać wszystkie wybrane efekty, również kanały powiadomień;
normalne pending nie jest błędem, ale paused zależności jest attention.

Filtr done oznacza kolumnę Przekazane, nie zamknięcie zgłoszenia Jira.
Statusy realnie obecne w repo sprawdzić w T01 i rozszerzyć fixture mapowania,
bez zmiany powyższej semantyki. Dla agent_work zakładka Analiza pokazuje wynik
istniejącego przebiegu lub „Brak analizy Jira”; nie generuje fikcyjnego wyniku.

Cursor: base64url JSON tuple `(detected_at,ref)` i hash filtrów; zły cursor 400.
Zapytanie UNION/projekcja musi stronicować i agregować w PostgreSQL, nie pobierać
całej historii do BEAM. Per-column używa tych samych filtrów i porządku.
API zwraca `actions` jako jawne booleany i powody odmowy; frontend nie wylicza uprawnień.

### 11.4. Realtime

Nowy topic `intake:workspace`, ten sam singleton Socket. Event `changed` zawiera
wyłącznie `project_id`, `case_ref?`, `rule_id?`, `revision` i `changed_at`.
Po commit invalidować odpowiednie React Query keys; debounce 250 ms.
Nie broadcastować sekretów, numerów ani treści analizy na wspólnym topicu.
Klucze: `[cases, filters]`, `[case, ref]`, `[case-events, ref]`, `[automations, filters]`,
`[automation, id]`, `[integrations]`. Szczegół dociągany REST.
Reconnect → refetch aktywnych query; fallback refetch 30 s tylko przy widocznym ekranie
i niedziałającym channel, nie drugi równoległy stały polling przy sprawnym WS.
Istniejące topics observability i klucze nie są przemianowywane.

## 12. Bezpieczeństwo i obserwowalność

- Jira site URL: wyłącznie HTTPS, host kończący się dokładnie `.atlassian.net`,
  bez userinfo/query/fragment; scoped API host stały. Brak dowolnego proxy URL.
- SMSAPI host stały. SMTP host ustala operator wdrożenia; UI może wybrać tylko
  host z runtime allowlist, nie skanować dowolnej sieci. Testy mają osobną allowlist loopback.
- Redirect HTTP nie przenosi Authorization na inny host. Archiwa forge używają
  kontrolowanego follow redirect bez tokenu na URL magazynu i z walidacją HTTPS.
- Opisy i wyniki nie trafiają do `dangerouslySetInnerHTML`; linki dopuszczają HTTPS
  i zaufane hosty Jira/Linear/forge/Harmony. `javascript:` i data URL odrzucane.
- Logi zawierają case_id/rule_id/delivery_id, etap, wynik, czas, request ID dostawcy;
  bez treści zgłoszeń, promptu, sekretów, pełnych adresatów i surowych response body.
- UI historii adresata maskuje; pełna lista dostępna tylko w formularzu konfiguracji
  w obecnym zaufanym środowisku. Nie dokładać fikcyjnych nazw operatorów do audytu.
- Metryki w Diagnostyce: backlog, najstarszy pending, stale lease, unknown,
  czas skanu, ostatni sukces reguły, analiza aktywna/limit, błędy kanałów.
- Dostęp do nowych mutacji chroniony CSRF; sekrety write-only z osobnym clear,
  pusty string zachowuje sekret, clear=true jawnie usuwa i wyłącza zależne aktywacje.
- Pliki snapshotu zawierają potencjalnie poufny kod: nie serwować ich przez artefact API,
  usuwać po zakończeniu/przerwaniu analizy, zachować SHA i walidowany wynik w DB.

## 13. Wdrożenie, migracja i rollback

Zmiany schematu addytywne; istniejące projekty/dane/historyczne runy zachowane.
UI działa także przy zerowej liczbie reguł Jira. Integracje i reguły domyślnie wyłączone.
Globalne `intake.enabled=false` zatrzymuje scheduler i nowe claimy efektów, nie usuwa
ExecutionGate ani powiązań. Efekty w locie kończą próbę; wynik zapisuje się normalnie.
`intake.effects_enabled=false` dodatkowo blokuje aktywację reguł i ręczne mutacje
zewnętrzne, w tym test-send, komentarz, import i nowe analizy.
ExecutionGate działa niezależnie od obu flag, także po rollbacku UI.

Runtime `intake` w WORKFLOW/Config: `enabled=false`, `effects_enabled=false`,
`public_url` (wymagany HTTPS przy włączeniu), `smtp_allowed_hosts=[]`.
Pozostałe stałe scheduler/dispatcher/limity z §6 i §10 nie mają edytora w UI v1.
Model/effort konfigurują operatorzy w sekcji analysis, nie w treści ticketu.
Bez zmiany istniejących portów aplikacji/DB; uruchomienie przez obecne `elixir/dev/harmony.sh`.

Kolejność rollout: migracje → guard → wyłączony intake → testy bezpieczeństwa →
UI A → konfiguracja połączeń → dry-run → jedna testowa reguła → ręczna zgoda na produkcję.
Przed testem live pokazać liczbę istniejących matches i wybraną initial_policy.
Nowy wygląd wdrożyć bez runtime wyboru A/B/C i bez martwej kopii starego shellu.

Rollback: wyłączyć intake i efekty, zachować DB i guard. Powrót do starego binarium
bez guard przy istniejących Todo z importu jest zabroniony. Przed takim downgrade
operator musi zatrzymać orchestrator i odizolować importy w Linear od jego aktywnego
zakresu, następnie zweryfikować to odczytem. Nie automatyzować masowej zmiany ticketów.
Down migration usuwa wyłącznie nowe tabele na pustym testowym DB; przy danych
produkcyjnych nie uruchamiać jej jako „rollback aplikacji”.

## 14. Kryteria odbioru i ryzyka

Każdy identyfikator AC ma odpowiadający test w planie; ręczny gate nie zastępuje unit testów.

| ID   | Weryfikowalny warunek                                                                                    |
| ---- | -------------------------------------------------------------------------------------------------------- |
| AC01 | A odtworzona w działającym React, desktop/mobile/dark, bez elementów demonstracyjnych.                   |
| AC02 | Lista/Kanban zachowują stan URL i filtry; per-column paginacja nie gubi kart ani liczników.              |
| AC03 | Badge projektu, hover/focus w kolorze, biała kropka 200 ms i reduced motion.                             |
| AC04 | Oba linki Jira/Linear identyczne wizualnie; brak URL nie daje aktywnego fałszywego linku.                |
| AC05 | Interwał i priorytety konfigurowalne; Todo w Linear sprawdzane po team ID.                               |
| AC06 | Stare zgłoszenie po awansie priorytetu przyjęte raz; spadek/ponowny awans nie duplikuje.                 |
| AC07 | Initial baseline, import istniejących, pauza/wznowienie i częściowa paginacja mają określone wyniki.     |
| AC08 | Równoległe skany/restart/timeout create dają jeden case i jedno docelowe Linear UUID.                    |
| AC09 | Import nigdy nie startuje implementacji bez zgody, także retry/restart/DB down/usunięcie etykiety.       |
| AC10 | Analiza nie zapisuje kodu, nie ma sekretów/narzędzi zapisujących, nie wykonuje hooków ani pętli Todo.    |
| AC11 | Wynik ma fakty/hipotezy/braki/źródła; błąd walidacji nie staje się komentarzem.                          |
| AC12 | Publikacja awaryjna ponawia tylko publikację; nie tworzy dodatkowego komentarza po niepewnym POST.       |
| AC13 | SMTP i SMSAPI działają niezależnie; unknown nie jest ślepo ponawiane; provider accepted ≠ delivered.     |
| AC14 | Sekrety szyfrowane i write-only; logi redagowane; CSRF/SSRF/XSS negatywne testy przechodzą.              |
| AC15 | Przyjmij nie startuje naprawy; osobna zgoda wersjonowana jest idempotentna i respektuje capacity/policy. |
| AC16 | Stare runy/projekty/artefakty/logi/stop/retry nadal dostępne; brak duplikatu case po naprawie.           |
| AC17 | Reconnect/refetch i stany empty/error/offline działają; brak pustej białej strony przy błędzie API.      |
| AC18 | Pełne bramki backend/frontend/E2E i manualny test kontrolowany mają surowe logi oraz kody wyjścia.       |
| AC19 | Rollback flag nie usuwa guard; brak nowych efektów przy wyłączonym intake/effects.                       |

Ryzyka wymagające jawnej bramki: wersja protokołu Codex i realna izolacja procesu,
uprawnienia Jira do komentarzy/filtra, dostępność Todo w Linear, niejednoznaczny
wynik SMTP i koszt segmentów SMS. Bez zaliczenia odpowiedniej bramki nie aktywować
reguły; nie zastępować jej implementacją „best effort”.

Nie rozwiązujemy tu historycznych usterek niezwiązanych z tym zakresem ani
nie nazywamy nieuruchomionych testów zaliczonymi. Gotowość dokumentów oznacza
gotowość do zatwierdzenia planu; gotowość funkcji wymaga wykonania wszystkich etapów.
