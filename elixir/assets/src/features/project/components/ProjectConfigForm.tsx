import { useEffect, type CSSProperties } from "react";
import { useForm, Controller } from "react-hook-form";
import { yupResolver } from "@hookform/resolvers/yup";
import {
  PROJECT_COLORS,
  projectFormSchema,
  toProjectInput,
  type ProjectFormValues,
} from "@/features/projects/projectSchema";
import { useCreateProject, useUpdateProject } from "@/features/projects/useProjects";
import { ApiError } from "@/lib/api";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Field,
  FieldDescription,
  FieldError,
  FieldGroup,
  FieldLabel,
  FieldLegend,
  FieldSet,
} from "@/components/ui/field";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { JsonEditor } from "@/components/JsonEditor";
import { Combobox } from "@/components/Combobox";
import { useForgeRepositories, useTrackerProjects } from "@/features/projects/usePickers";
import type { Project, ProjectColor } from "@/types/contract";

const COLOR_LABELS: Record<ProjectColor, string> = {
  purple: "Fioletowy",
  gold: "Złoty",
  teal: "Morski",
};

const FIELDS = [
  { name: "slug", label: "Slug" },
  { name: "linear_human_review_state", label: "Stan przeglądu człowieka w Linear" },
] as const;

const SECRETS = [
  {
    name: "forge_secret",
    clearName: "clear_forge_secret",
    label: "Token forge",
    state: (p?: Project) => p?.forge_secret ?? "unset",
  },
  {
    name: "tracker_secret",
    clearName: "clear_tracker_secret",
    label: "Klucz trackera",
    state: (p?: Project) => p?.tracker_secret ?? "unset",
  },
] as const;

// Maps the stored forge value to its display label so the Select trigger shows
// "GitHub" rather than the raw "github" value.
const FORGE_LABELS: Record<string, string> = { github: "GitHub", gitlab: "GitLab" };

const SECRET_STATE_LABEL: Record<string, string> = { set: "ustawiony", unset: "nieustawiony" };

function serverFieldToFormField(field: string): keyof ProjectFormValues {
  if (field === "config") return "config_json";
  return field as keyof ProjectFormValues;
}

function errorId(field: string) {
  return `${field}-error`;
}

interface ProjectConfigFormProps {
  project?: Project;
  onSuccess?: () => void;
}

export function ProjectConfigForm({ project, onSuccess }: ProjectConfigFormProps) {
  const editing = !!project;
  const createMut = useCreateProject();
  const updateMut = useUpdateProject(project?.id ?? "");
  const isSaving = createMut.isPending || updateMut.isPending;
  const repos = useForgeRepositories();
  const projects = useTrackerProjects();

  const {
    register,
    handleSubmit,
    reset,
    setError,
    setValue,
    watch,
    control,
    formState: { errors, isSubmitting },
  } = useForm<ProjectFormValues>({
    resolver: yupResolver(projectFormSchema),
    defaultValues: {
      config_version: 1,
      config_json: "{}",
      forge_type: "github",
      display_name: "",
      ui_color: "purple",
    },
  });

  const forgeType = watch("forge_type") ?? "github";
  const forgeBaseUrl = watch("forge_base_url") ?? "";
  const forgeToken = watch("forge_secret") ?? "";
  const trackerToken = watch("tracker_secret") ?? "";
  const owner = watch("github_owner");
  const repo = watch("github_repo");
  const linearSlug = watch("linear_project_slug");

  useEffect(() => {
    if (project) {
      reset({
        slug: project.slug,
        display_name: project.display_name ?? "",
        ui_color: project.ui_color ?? "purple",
        github_owner: project.github_owner,
        github_repo: project.github_repo,
        github_base_branch: project.github_base_branch,
        forge_type: project.forge_type ?? "github",
        forge_base_url: project.forge_base_url ?? "",
        linear_project_slug: project.linear_project_slug ?? "",
        linear_team_key: project.linear_team_key ?? "",
        linear_human_review_state: project.linear_human_review_state ?? "",
        forge_secret: "",
        tracker_secret: "",
        clear_forge_secret: false,
        clear_tracker_secret: false,
        config_version: project.config_version,
        config_json: JSON.stringify(project.config ?? {}, null, 2),
      });
    }
  }, [project, reset]);

  async function onSubmit(values: ProjectFormValues) {
    const input = toProjectInput(values);
    try {
      if (editing) {
        await updateMut.mutateAsync(input);
      } else {
        await createMut.mutateAsync(input);
      }
      onSuccess?.();
    } catch (err) {
      if (err instanceof ApiError && err.fields) {
        for (const [field, messages] of Object.entries(err.fields)) {
          setError(serverFieldToFormField(field), { message: messages.join(", ") });
        }
      } else if (err instanceof ApiError) {
        toast.error(err.message);
      } else {
        toast.error("Nieoczekiwany błąd zapisu projektu");
      }
    }
  }

  return (
    <form className="max-w-xl" onSubmit={handleSubmit(onSubmit)}>
      <FieldGroup>
        <Field data-invalid={errors.display_name ? true : undefined}>
          <FieldLabel htmlFor="display_name">Nazwa wyświetlana</FieldLabel>
          <Input
            id="display_name"
            aria-invalid={errors.display_name ? true : undefined}
            aria-describedby={
              errors.display_name
                ? `display_name-description ${errorId("display_name")}`
                : "display_name-description"
            }
            {...register("display_name")}
          />
          <FieldDescription id="display_name-description">
            Do 100 znaków. Bez nazwy projekt jest widoczny pod swoim slugiem.
          </FieldDescription>
          <FieldError id={errorId("display_name")} errors={[errors.display_name]} />
        </Field>

        <FieldSet
          role="radiogroup"
          aria-labelledby="ui_color-legend"
          aria-describedby="ui_color-description"
          data-invalid={errors.ui_color ? true : undefined}
        >
          <FieldLegend id="ui_color-legend" variant="label">
            Kolor projektu
          </FieldLegend>
          <div className="flex flex-wrap gap-2">
            {PROJECT_COLORS.map((color) => (
              <label
                key={color}
                style={{ "--project-color": `var(--project-${color})` } as CSSProperties}
                className="flex cursor-pointer items-center gap-2 rounded-[7px] border bg-card px-3 py-2 text-xs has-checked:border-(--project-color) has-checked:bg-[color-mix(in_srgb,var(--project-color)_12%,var(--card))] has-focus-visible:outline-3 has-focus-visible:outline-offset-3 has-focus-visible:outline-ring"
              >
                <input type="radio" value={color} className="sr-only" {...register("ui_color")} />
                <span aria-hidden className="size-4 rounded-full bg-(--project-color)" />
                {COLOR_LABELS[color]}
              </label>
            ))}
          </div>
          <FieldDescription id="ui_color-description">
            Kolor rozróżnia projekty w nawigacji i nie oznacza stanu projektu.
          </FieldDescription>
          <FieldError id={errorId("ui_color")} errors={[errors.ui_color]} />
        </FieldSet>

        {FIELDS.map((f) => (
          <Field key={f.name} data-invalid={errors[f.name] ? true : undefined}>
            <FieldLabel htmlFor={f.name}>{f.label}</FieldLabel>
            <Input
              id={f.name}
              aria-invalid={errors[f.name] ? true : undefined}
              aria-describedby={errors[f.name] ? errorId(f.name) : undefined}
              {...register(f.name)}
            />
            <FieldError id={errorId(f.name)} errors={[errors[f.name]]} />
          </Field>
        ))}

        {SECRETS.map((s) => (
          <Field key={s.name}>
            <FieldLabel htmlFor={s.name}>
              {s.label} — obecnie: {SECRET_STATE_LABEL[s.state(project)] ?? s.state(project)}
            </FieldLabel>
            <Input
              id={s.name}
              type="password"
              autoComplete="new-password"
              placeholder={editing ? "Pozostaw puste, aby zachować obecny" : ""}
              {...register(s.name)}
            />
            {editing ? (
              <Field orientation="horizontal">
                <Controller
                  name={s.clearName}
                  control={control}
                  render={({ field }) => (
                    <Checkbox
                      id={s.clearName}
                      checked={!!field.value}
                      onCheckedChange={(checked) => field.onChange(checked === true)}
                    />
                  )}
                />
                <FieldLabel htmlFor={s.clearName} className="font-normal text-muted-foreground">
                  Wyczyść (przywróć wartość domyślną ze środowiska)
                </FieldLabel>
              </Field>
            ) : null}
          </Field>
        ))}

        <Field>
          <FieldLabel htmlFor="forge_type">Forge</FieldLabel>
          <Controller
            name="forge_type"
            control={control}
            render={({ field }) => (
              <Select items={FORGE_LABELS} value={field.value} onValueChange={field.onChange}>
                <SelectTrigger id="forge_type" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="github">GitHub</SelectItem>
                  <SelectItem value="gitlab">GitLab</SelectItem>
                </SelectContent>
              </Select>
            )}
          />
        </Field>

        <Field>
          <FieldLabel htmlFor="forge_base_url">Adres bazowy forge (self-host, opcjonalnie)</FieldLabel>
          <Input id="forge_base_url" {...register("forge_base_url")} />
        </Field>

        <Field>
          <FieldLabel>Repozytorium</FieldLabel>
          <Combobox
            label="Repozytorium"
            value={owner && repo ? { value: `${owner}/${repo}`, label: `${owner}/${repo}` } : null}
            items={(repos.data?.repositories ?? []).map((r) => ({
              value: `${r.owner}/${r.name}`,
              label: `${r.owner}/${r.name}`,
            }))}
            loading={repos.isPending}
            error={repos.isError ? "Nie udało się pobrać repozytoriów — sprawdź token i spróbuj ponownie." : null}
            onOpen={() =>
              repos.mutate({ forge_type: forgeType, base_url: forgeBaseUrl || null, token: forgeToken || null })
            }
            onSelect={(item) => {
              const r = (repos.data?.repositories ?? []).find((x) => `${x.owner}/${x.name}` === item.value);
              if (r) {
                setValue("github_owner", r.owner, { shouldDirty: true });
                setValue("github_repo", r.name, { shouldDirty: true });
                setValue("github_base_branch", r.default_branch, { shouldDirty: true });
              }
            }}
          />
          <FieldDescription>Wybrany właściciel, repozytorium i gałąź bazowa:</FieldDescription>
          <Input aria-label="Właściciel repozytorium" {...register("github_owner")} readOnly />
          <Input aria-label="Nazwa repozytorium" {...register("github_repo")} readOnly />
          <Input aria-label="Gałąź bazowa" {...register("github_base_branch")} readOnly />
        </Field>

        <Field>
          <FieldLabel>Projekt Linear</FieldLabel>
          <Combobox
            label="Projekt Linear"
            value={linearSlug ? { value: linearSlug, label: linearSlug } : null}
            items={(projects.data?.projects ?? []).map((p) => ({
              value: p.slug,
              label: `${p.name} (${p.team_key})`,
            }))}
            loading={projects.isPending}
            error={projects.isError ? "Nie udało się pobrać projektów — sprawdź token i spróbuj ponownie." : null}
            onOpen={() => projects.mutate({ token: trackerToken || null, base_url: null })}
            onSelect={(item) => {
              const p = (projects.data?.projects ?? []).find((x) => x.slug === item.value);
              if (p) {
                setValue("linear_project_slug", p.slug, { shouldDirty: true });
                setValue("linear_team_key", p.team_key, { shouldDirty: true });
              }
            }}
          />
          <Input aria-label="Slug projektu Linear" {...register("linear_project_slug")} readOnly />
          <input type="hidden" {...register("linear_team_key")} />
        </Field>

        <Field data-invalid={errors.config_version ? true : undefined}>
          <FieldLabel htmlFor="config_version">Wersja konfiguracji</FieldLabel>
          <Input
            id="config_version"
            type="number"
            aria-invalid={errors.config_version ? true : undefined}
            aria-describedby={errors.config_version ? errorId("config_version") : undefined}
            {...register("config_version")}
          />
          <FieldError id={errorId("config_version")} errors={[errors.config_version]} />
        </Field>

        <Field data-invalid={errors.config_json ? true : undefined}>
          <FieldLabel htmlFor="config_json">Konfiguracja (JSON)</FieldLabel>
          <Controller
            name="config_json"
            control={control}
            render={({ field }) => (
              <JsonEditor
                value={field.value}
                onChange={field.onChange}
                ariaLabel="Konfiguracja (JSON)"
                ariaDescribedBy={errors.config_json ? errorId("config_json") : undefined}
              />
            )}
          />
          <FieldError id={errorId("config_json")} errors={[errors.config_json]} />
        </Field>

        <Button type="submit" disabled={isSubmitting || isSaving}>
          Zapisz
        </Button>
      </FieldGroup>
    </form>
  );
}
