defmodule SymphonyElixir.ProjectConfig.Schema do
  @moduledoc """
  Typed per-project configuration loaded from projects/*.yaml.
  """

  defmodule Linear do
    @moduledoc false
    defstruct [:project_slug, :team_key, :human_review_state]
  end

  defmodule Github do
    @moduledoc false
    defstruct [:owner, :repo, :base_branch, protected_branches: []]
  end

  defmodule Review do
    @moduledoc false
    defstruct trigger: "@hreview", template_version: 1
  end

  defstruct [:slug, :linear, :github, :review, raw: %{}]

  @type t :: %__MODULE__{}

  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%{} = raw) do
    raw = normalize_keys(raw)

    with {:ok, slug} <- required_string(raw, "slug"),
         {:ok, linear} <- parse_linear(Map.get(raw, "linear", %{})),
         {:ok, github} <- parse_github(Map.get(raw, "github", %{})),
         {:ok, review} <- parse_review(Map.get(raw, "review", %{})) do
      {:ok, %__MODULE__{slug: slug, linear: linear, github: github, review: review, raw: raw}}
    end
  end

  def parse(_raw), do: {:error, :project_config_not_a_map}

  defp parse_linear(raw) when is_map(raw) do
    with {:ok, project_slug} <- required_string(raw, "project_slug"),
         {:ok, human_review_state} <- required_string(raw, "human_review_state") do
      {:ok,
       %Linear{
         project_slug: project_slug,
         team_key: optional_string(raw, "team_key"),
         human_review_state: human_review_state
       }}
    end
  end

  defp parse_linear(_raw), do: {:error, {:invalid_project_config_section, "linear"}}

  defp parse_github(raw) when is_map(raw) do
    with {:ok, owner} <- required_string(raw, "owner"),
         {:ok, repo} <- required_string(raw, "repo"),
         {:ok, base_branch} <- required_string(raw, "base_branch") do
      protected_branches =
        raw
        |> Map.get("protected_branches", [])
        |> normalize_string_list()

      {:ok, %Github{owner: owner, repo: repo, base_branch: base_branch, protected_branches: protected_branches}}
    end
  end

  defp parse_github(_raw), do: {:error, {:invalid_project_config_section, "github"}}

  defp parse_review(raw) when is_map(raw) do
    {:ok,
     %Review{
       trigger: optional_string(raw, "trigger") || "@hreview",
       template_version: optional_integer(raw, "template_version") || 1
     }}
  end

  defp parse_review(_raw), do: {:error, {:invalid_project_config_section, "review"}}

  defp required_string(raw, key) do
    case optional_string(raw, key) do
      nil -> {:error, {:missing_project_config_field, key}}
      value -> {:ok, value}
    end
  end

  defp optional_string(raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp optional_integer(raw, key) do
    case Map.get(raw, key) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_values), do: []

  defp normalize_keys(%{} = map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), normalize_keys(value)}
    end)
  end

  defp normalize_keys(values) when is_list(values), do: Enum.map(values, &normalize_keys/1)
  defp normalize_keys(value), do: value
end
