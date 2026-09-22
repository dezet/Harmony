defmodule SymphonyElixir.Intake do
  @moduledoc """
  Runtime boundary for the durable Jira intake subsystem.

  All runtime switches come from `SymphonyElixir.Config`; this module does not
  read environment variables or maintain a second configuration source.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Intake.Rules

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings, do: Config.settings()

  @spec runtime_settings() :: Schema.t()
  def runtime_settings, do: Config.settings!()

  @spec enabled?(Schema.t() | nil) :: boolean()
  def enabled?(settings \\ nil) do
    settings = settings || runtime_settings()
    settings.intake.enabled
  end

  @spec effects_enabled?(Schema.t() | nil) :: boolean()
  def effects_enabled?(settings \\ nil) do
    settings = settings || runtime_settings()
    settings.intake.effects_enabled
  end

  @spec analysis_enabled?(Schema.t() | nil) :: boolean()
  def analysis_enabled?(settings \\ nil) do
    settings = settings || runtime_settings()
    settings.analysis.enabled
  end

  @spec analysis_profile(keyword()) :: {:ok, %{model: String.t(), effort: String.t()}} | {:error, :analysis_profile_unavailable}
  def analysis_profile(opts \\ []) do
    settings = runtime_settings().analysis
    enabled? = Keyword.get(opts, :analysis_enabled, settings.enabled)
    model = Keyword.get(opts, :analysis_model, settings.model)
    effort = Keyword.get(opts, :analysis_effort, settings.effort)

    if enabled? and nonempty_string?(model) and nonempty_string?(effort) do
      {:ok, %{model: String.trim(model), effort: String.trim(effort)}}
    else
      {:error, :analysis_profile_unavailable}
    end
  end

  @spec rule_snapshot(SymphonyElixir.Storage.AutomationRule.t(), DateTime.t() | nil) :: map()
  def rule_snapshot(rule, qualified_at \\ nil), do: Rules.snapshot(rule, qualified_at)

  @spec snapshot_case_attrs(map(), SymphonyElixir.Storage.AutomationRule.t(), DateTime.t() | nil) :: map()
  def snapshot_case_attrs(attrs, rule, qualified_at \\ nil) when is_map(attrs) do
    Map.put(attrs, :rule_snapshot, rule_snapshot(rule, qualified_at))
  end

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
