defmodule SymphonyElixir.Github.LinkResolver do
  @moduledoc """
  Resolves Linear issue references from GitHub PR metadata.
  """

  @linear_url_regex ~r"https://linear\.app/[^\s)]+/issue/([A-Z][A-Z0-9]+-\d+)/[^\s)]*"

  @spec resolve(map(), keyword()) :: map() | nil
  def resolve(pr, opts \\ []) when is_map(pr) do
    team_keys = Keyword.get(opts, :team_keys, [])
    text = Enum.join([Map.get(pr, :body), Map.get(pr, :head_ref), Map.get(pr, :title)], "\n")

    url_match = Regex.run(@linear_url_regex, text)
    identifier = identifier_from_url_match(url_match) || identifier_from_text(text, team_keys)

    case identifier do
      nil -> nil
      value -> %{identifier: value, url: url_from_match(url_match)}
    end
  end

  defp identifier_from_url_match([_url, identifier]), do: identifier
  defp identifier_from_url_match(_match), do: nil

  defp url_from_match([url, _identifier]), do: url
  defp url_from_match(_match), do: nil

  defp identifier_from_text(text, team_keys) do
    team_keys
    |> Enum.map(&Regex.escape/1)
    |> case do
      [] -> nil
      escaped -> Regex.run(~r"\b(#{Enum.join(escaped, "|")})-\d+\b"i, text)
    end
    |> case do
      [identifier | _captures] -> String.upcase(identifier)
      _missing -> nil
    end
  end
end
