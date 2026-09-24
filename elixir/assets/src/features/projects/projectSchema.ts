import * as yup from "yup";
import type { ProjectColor, ProjectInput } from "@/types/contract";

export const PROJECT_COLORS: readonly ProjectColor[] = ["purple", "gold", "teal"];
export const DISPLAY_NAME_MAX = 100;

// The form holds `config` as a JSON string in a textarea. This schema validates
// the string parses to a JSON object, and toProjectInput transforms it.
export const projectFormSchema = yup.object({
  slug: yup.string().trim().required("Podaj slug projektu"),
  github_owner: yup.string().trim().required("Wybierz repozytorium (właściciel)"),
  github_repo: yup.string().trim().required("Wybierz repozytorium"),
  github_base_branch: yup.string().trim().required("Podaj gałąź bazową"),
  display_name: yup
    .string()
    .trim()
    .max(DISPLAY_NAME_MAX, `Nazwa może mieć najwyżej ${DISPLAY_NAME_MAX} znaków`)
    .default(""),
  ui_color: yup
    .mixed<ProjectColor>()
    .oneOf(PROJECT_COLORS, "Wybierz jeden z trzech kolorów")
    .required("Wybierz kolor projektu")
    .default("purple"),
  forge_type: yup.string().trim().default("github"),
  forge_base_url: yup.string().trim().default(""),
  linear_project_slug: yup.string().trim().default(""),
  linear_team_key: yup.string().trim().default(""),
  linear_human_review_state: yup.string().trim().default(""),
  forge_secret: yup.string().default(""),
  tracker_secret: yup.string().default(""),
  clear_forge_secret: yup.boolean().default(false),
  clear_tracker_secret: yup.boolean().default(false),
  config_version: yup
    .number()
    .typeError("Wersja musi być liczbą")
    .integer("Wersja musi być liczbą całkowitą")
    .min(1, "Wersja musi być co najmniej 1")
    .required("Podaj wersję konfiguracji"),
  config_json: yup
    .string()
    .default("{}")
    .test("is-json-object", "Konfiguracja musi być obiektem JSON", (value) => {
      try {
        const parsed = JSON.parse(value || "{}");
        return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed);
      } catch {
        return false;
      }
    }),
});

export type ProjectFormValues = yup.InferType<typeof projectFormSchema>;

export function toProjectInput(values: ProjectFormValues): ProjectInput {
  const input: ProjectInput = {
    slug: values.slug,
    github_owner: values.github_owner,
    github_repo: values.github_repo,
    github_base_branch: values.github_base_branch,
    forge_type: values.forge_type || "github",
    forge_base_url: values.forge_base_url || null,
    // A blank name is sent as null: the project is then shown by its slug.
    display_name: values.display_name || null,
    ui_color: values.ui_color,
    linear_project_slug: values.linear_project_slug || null,
    linear_team_key: values.linear_team_key || null,
    linear_human_review_state: values.linear_human_review_state || null,
    config_version: values.config_version,
    config: JSON.parse(values.config_json || "{}"),
  };

  // Write-only secrets: send a value only when entered; send the clear flag only
  // when checked. Never round-trip a secret value back from the server.
  if (values.forge_secret) input.forge_secret = values.forge_secret;
  if (values.tracker_secret) input.tracker_secret = values.tracker_secret;
  if (values.clear_forge_secret) input.clear_forge_secret = true;
  if (values.clear_tracker_secret) input.clear_tracker_secret = true;

  return input;
}
