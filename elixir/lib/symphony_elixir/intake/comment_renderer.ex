defmodule SymphonyElixir.Intake.CommentRenderer do
  @moduledoc "Renders validated analysis data as deterministic, text-only Jira ADF."

  alias SymphonyElixir.Storage.IntakeCase

  @property_key "harmony.analysis"

  @spec render(IntakeCase.t(), pos_integer(), map(), map()) :: map()
  def render(%IntakeCase{} = intake_case, version, result, input_snapshot)
      when is_integer(version) and version > 0 and is_map(result) and is_map(input_snapshot) do
    marker = "Harmony analysis #{intake_case.id}/v#{version}"

    content =
      [
        heading("Analiza Harmony — #{intake_case.jira_key}", 2),
        paragraph(result["summary"]),
        section("Fakty", Enum.map(result["facts"], &fact_text/1)),
        section("Hipotezy", Enum.map(result["hypotheses"], &hypothesis_text/1)),
        section("Brakujące dane", result["missing_data"]),
        section("Kolejne kroki", result["next_steps"]),
        paragraph("Linear: #{display_value(intake_case.linear_url)}"),
        paragraph(context_description(intake_case, input_snapshot)),
        paragraph("Nie wykonano zmian w kodzie"),
        paragraph(marker)
      ]
      |> List.flatten()

    %{
      body: %{"version" => 1, "type" => "doc", "content" => content},
      marker: marker,
      property: %{"key" => @property_key, "value" => marker}
    }
  end

  defp heading(text, level) do
    %{
      "type" => "heading",
      "attrs" => %{"level" => level},
      "content" => [%{"type" => "text", "text" => text}]
    }
  end

  defp section(title, entries) do
    rows =
      case entries do
        [] -> [list_item("Brak danych")]
        values -> Enum.map(values, &list_item(&1))
      end

    [heading(title, 3), %{"type" => "bulletList", "content" => rows}]
  end

  defp list_item(text) do
    %{
      "type" => "listItem",
      "content" => [paragraph(text)]
    }
  end

  defp paragraph(text) when is_binary(text) do
    %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}
  end

  defp fact_text(%{"text" => text, "source" => source}), do: "#{text} — źródło: #{source}"

  defp hypothesis_text(%{"text" => text, "confidence" => confidence, "evidence" => evidence}) do
    "Hipoteza (#{confidence}): #{text} — dowody: #{Enum.join(evidence, ", ")}"
  end

  defp context_description(intake_case, input_snapshot) do
    context_date =
      case intake_case.detected_at do
        %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
        _missing -> "data nieznana"
      end

    sha = Map.get(input_snapshot, "repository_sha")
    scope = Map.get(input_snapshot, "context_scope", "issue_only")
    reason = Map.get(input_snapshot, "context_reason")

    repository =
      case {scope, sha, reason} do
        {"issue_and_repository", value, _reason} when is_binary(value) -> "Repozytorium SHA: #{value}"
        {"issue_only", _value, value} when is_binary(value) -> "Zakres: issue_only (#{value})"
        _other -> "Zakres: #{scope}"
      end

    "Kontekst z dnia #{context_date}. #{repository}."
  end

  defp display_value(value) when is_binary(value) and value != "", do: value
  defp display_value(_value), do: "brak"
end
