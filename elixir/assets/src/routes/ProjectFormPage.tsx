import { useEffect } from "react";
import { useForm } from "react-hook-form";
import { yupResolver } from "@hookform/resolvers/yup";
import { useNavigate, useParams } from "react-router-dom";
import {
  projectFormSchema,
  toProjectInput,
  type ProjectFormValues,
} from "@/features/projects/projectSchema";
import { useCreateProject, useProject, useUpdateProject } from "@/features/projects/useProjects";
import { ApiError } from "@/lib/api";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";

const FIELDS = [
  { name: "slug", label: "Slug" },
  { name: "github_owner", label: "GitHub owner" },
  { name: "github_repo", label: "GitHub repo" },
  { name: "github_base_branch", label: "Base branch" },
  { name: "linear_project_slug", label: "Linear project slug" },
  { name: "linear_team_key", label: "Linear team key" },
  { name: "linear_human_review_state", label: "Linear human review state" },
] as const;

export function ProjectFormPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const editing = !!id;
  const { data: project } = useProject(id);
  const createMut = useCreateProject();
  const updateMut = useUpdateProject(id ?? "");

  const {
    register,
    handleSubmit,
    reset,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<ProjectFormValues>({
    resolver: yupResolver(projectFormSchema),
    defaultValues: { config_version: 1, config_json: "{}" },
  });

  useEffect(() => {
    if (project) {
      reset({
        slug: project.slug,
        github_owner: project.github_owner,
        github_repo: project.github_repo,
        github_base_branch: project.github_base_branch,
        linear_project_slug: project.linear_project_slug ?? "",
        linear_team_key: project.linear_team_key ?? "",
        linear_human_review_state: project.linear_human_review_state ?? "",
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
      navigate("/projects");
    } catch (err) {
      if (err instanceof ApiError && err.fields) {
        for (const [field, messages] of Object.entries(err.fields)) {
          setError(field as keyof ProjectFormValues, { message: messages.join(", ") });
        }
      } else if (err instanceof ApiError) {
        toast.error(err.message);
      } else {
        toast.error("Unexpected error saving the project");
      }
    }
  }

  return (
    <form className="max-w-xl space-y-4" onSubmit={handleSubmit(onSubmit)}>
      <h1 className="text-2xl font-semibold">{editing ? "Edit project" : "New project"}</h1>

      {FIELDS.map((f) => (
        <div key={f.name} className="space-y-1">
          <Label htmlFor={f.name}>{f.label}</Label>
          <Input id={f.name} {...register(f.name)} />
          {errors[f.name] ? (
            <p className="text-sm text-destructive">{errors[f.name]?.message}</p>
          ) : null}
        </div>
      ))}

      <div className="space-y-1">
        <Label htmlFor="config_version">Config version</Label>
        <Input id="config_version" type="number" {...register("config_version")} />
        {errors.config_version ? (
          <p className="text-sm text-destructive">{errors.config_version.message}</p>
        ) : null}
      </div>

      <div className="space-y-1">
        <Label htmlFor="config_json">Config (JSON)</Label>
        <Textarea id="config_json" rows={8} {...register("config_json")} />
        {errors.config_json ? (
          <p className="text-sm text-destructive">{errors.config_json.message}</p>
        ) : null}
      </div>

      <Button type="submit" disabled={isSubmitting}>
        Save
      </Button>
    </form>
  );
}
