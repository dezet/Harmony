---
title: "Harmony UI/Jira — przekazanie do nowej sesji"
date: 2026-09-23
status: blocked-at-t15
audience: coding-agent
---

# Harmony UI/Jira — przekazanie do nowej sesji

## Cel i źródła

Wdrażamy zaakceptowany wariant A Centrum spraw (Lista/Kanban) oraz przepływ Jira Cloud → alert SMTP/SMSAPI → Linear Todo → analiza tylko do odczytu → komentarz Jira. Automatyczna naprawa i produkcyjna aktywacja reguł nie należą do tego etapu.

- [Plan i kontrakt wykonania](../plans/2026-09-22-harmony-ui-jira.md), szczególnie §1 oraz T15–T29.
- [Specyfikacja](../specs/2026-09-22-harmony-ui-jira-design.md), dla T15 szczególnie §10.1–10.2 i §10.4–10.5.
- Zaakceptowana [interaktywna makieta A](../../mockups/index.html), z [CSS](../../mockups/styles.css) i [JS](../../mockups/app.js).
- Lokalne, nieśledzone zrzuty: `/home/ddziag/projects/Harmony/output/t00-preflight/harmony-a-list-1440x1050.png`, `harmony-a-kanban-1440x1050.png`, wersje mobilne i szczegół; także `output/playwright/`.
- Instrukcje repo: `elixir/AGENTS.md` oraz globalne `~/.codex/AGENTS.md`.

Plan ma siedem milestone’ów: M0–M6. Zadania wykonuje się kolejno, osobne Txx jako osobne zlecenia. Użytkownik wymaga subagentów **gpt-6-luna, reasoning_effort=max**, z czystym kontekstem (`fork_turns: "none"`), oraz pełnych testów aplikacji dopiero na końcu milestone’u. Każdy agent ma pokazać RED przed implementacją oraz dosłowne komendy, surowe wyniki i kody wyjścia; koordynator powtarza sprawdzenia. Nie wykonywać testów z realnym mailem/SMS, zapisów do produkcyjnych Jira/Linear ani płatnej analizy.

## Stan zweryfikowany 23 września 2026

| Etap | Stan |
| --- | --- |
| M0 | Ukończony i scalony; PR [#17](https://github.com/dezet/Harmony/pull/17) scalony. |
| M1 | Ukończony i scalony; PR [#18](https://github.com/dezet/Harmony/pull/18) scalony. |
| M2 | Ukończony i scalony; PR [#19](https://github.com/dezet/Harmony/pull/19) scalony. |
| M3 | Ukończony i scalony; PR [#20](https://github.com/dezet/Harmony/pull/20) scalony jako `db2d0d16ce1e7344e46d84ca777cb704ff2665bc`. |
| M4 | Gałąź i worktree utworzone; T15 rozpoczęty, ale zablokowany na pobraniu zależności Hex. PR M4 nie utworzono, bo nie ma ukończonej zmiany. |
| M5–M6 | Nie rozpoczęto. |

Po scaleniu M3 wykonano w worktree M4 pełne `make all` z kodem **0**: 890 testów, 0 błędów, 2 pominięte, pokrycie 85,02%, Dialyzer 0 błędów. Log z `/tmp` nie przetrwał. `git fetch --tags origin` zakończył się kodem 0; GitHub API potwierdziło scalenie PR #17–#20. Aktualne `origin/main` to `db2d0d1`.

## Aktywny worktree i bloker T15

- Worktree: `/home/ddziag/projects/Harmony-m4` (poprzedni `/tmp/harmony-m4` został wyczyszczony; niecommitowane zmiany odtworzono z logu sesji Codex); gałąź `feature/harmony-ui-jira-m4`, HEAD `db2d0d1`, bazuje na `origin/main`.
- Niecommitowane zmiany: `elixir/mix.exs` (deklaracje `swoosh ~> 1.28.0`, `gen_smtp ~> 1.3.0`) oraz nowy `elixir/test/symphony_elixir/notification_smtp_test.exs` (sześć testów RED). Lockfile, adapter SMTP, szablony i test Mailpit jeszcze nie powstały.
- Agent T15 uruchomił przed implementacją `CLOAK_KEY="$(python3 -c 'print("k" * 64)')" mise exec -- mix test test/symphony_elixir/notification_smtp_test.exs`: exit **2**, `6 tests, 6 failures`, ponieważ moduły `Notifications.Templates` i `Notifications.Smtp` nie istnieją.
- `mise exec -- mix deps.get` po ponowieniu, także eskalowanym, zakończył się kodem **1**: `No package with name swoosh (from: mix.exs) in registry`. Bezpośredni `curl -IL --connect-timeout 5 --max-time 15 https://repo.hex.pm/installs/hex-1.x.csv` zakończył się kodem **28** (`Connection timed out`). Zależności nie są w lokalnym cache.
- Koordynator powtórzył `CLOAK_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= HEX_OFFLINE=1 mise exec -- mix specs.check`: exit **1**, brak `gen_smtp` i `swoosh`. `git diff --check`: exit **0**. GREEN T15 nie istnieje; jego testów nie da się teraz uruchomić z nowymi deklaracjami zależności.

Nie zastępować Swoosh/gen_smtp własnym transportem. Po przywróceniu dostępu do Hex dokończyć wyłącznie T15 z planu, uruchomić test jednostkowy T15 i `mix specs.check`, przejrzeć zmiany oraz niezależnie powtórzyć wyniki agenta. Integracja Mailpit należy do globalnej bramki, nie do testowania po każdym zadaniu. **Użytkownik nakazał zatrzymać pracę po T15**: nie rozpoczynać T16, nawet jeśli T15 zostanie domknięty. Obecnie T15 jest zablokowany, a nie ukończony.

## Pozostała praca według planu

- M4: T15 SMTP i szablony; T16 SMSAPI; T17 REST/CSRF; T18 projekcja spraw; T19 Phoenix Channel i React Query.
- M5: T20–T25, interfejs A (shell, Lista, szczegół, Kanban, automatyzacje, integracje).
- M6: T26–T29, regresja, E2E/wizualna, dokumentacja, pełna weryfikacja i kontrolowane uruchomienie.

Nie zmieniać głównego checkoutu `/home/ddziag/projects/Harmony`, który nadal jest na gałęzi M2 i ma lokalne `output/`. Worktree M3 w `/tmp` już nie istnieje; gałąź M3 jest scalona. Handoff i zmiany T15 znajdują się wyłącznie w worktree M4 i nie są zacommitowane; przed dalszą pracą sprawdzić `git status --short --branch` oraz aktualny stan zdalnego repozytorium.
