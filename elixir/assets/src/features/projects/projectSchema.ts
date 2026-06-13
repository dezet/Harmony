import * as yup from "yup";
import type { ProjectInput } from "@/types/contract";

// The form holds `config` as a JSON string in a textarea. This schema validates
// the string parses to a JSON object, and toProjectInput transforms it.
export const projectFormSchema = yup.object({
  slug: yup.string().trim().required("Slug is required"),
  github_owner: yup.string().trim().required("GitHub owner is required"),
  github_repo: yup.string().trim().required("GitHub repo is required"),
  github_base_branch: yup.string().trim().required("Base branch is required"),
  linear_project_slug: yup.string().trim().default(""),
  linear_team_key: yup.string().trim().default(""),
  linear_human_review_state: yup.string().trim().default(""),
  forge_secret: yup.string().default(""),
  tracker_secret: yup.string().default(""),
  clear_forge_secret: yup.boolean().default(false),
  clear_tracker_secret: yup.boolean().default(false),
  config_version: yup
    .number()
    .typeError("Version must be a number")
    .integer()
    .min(1)
    .required("Version is required"),
  config_json: yup
    .string()
    .default("{}")
    .test("is-json-object", "Config must be a JSON object", (value) => {
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
