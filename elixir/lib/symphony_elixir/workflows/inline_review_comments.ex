defmodule SymphonyElixir.Workflows.InlineReviewComments do
  @moduledoc """
  Maps proposed review comments onto lines that exist in the current PR diff.
  """

  @default_max_comments 10

  @type proposed_comment :: %{
          required(:path) => String.t(),
          required(:line) => pos_integer(),
          required(:body) => String.t()
        }

  @type github_comment :: %{
          required(:path) => String.t(),
          required(:line) => pos_integer(),
          required(:side) => String.t(),
          required(:body) => String.t()
        }

  @spec map(String.t(), [proposed_comment()]) :: [github_comment()]
  def map(diff, comments), do: map(diff, comments, [])

  @spec map(String.t(), [proposed_comment()], keyword()) :: [github_comment()]
  def map(diff, comments, opts) when is_binary(diff) and is_list(comments) and is_list(opts) do
    allowed_lines = right_side_diff_lines(diff)
    max_comments = max_comments(opts)

    comments
    |> Enum.filter(&valid_comment?(&1, allowed_lines))
    |> Enum.map(&to_github_comment/1)
    |> Enum.take(max_comments)
  end

  defp right_side_diff_lines(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce(%{path: nil, new_line: nil, lines: MapSet.new()}, &parse_diff_line/2)
    |> Map.fetch!(:lines)
  end

  defp parse_diff_line("+++ b/" <> path, state), do: %{state | path: path}
  defp parse_diff_line("+++ " <> _path, state), do: %{state | path: nil}

  defp parse_diff_line("@@ " <> rest, %{path: path} = state) when is_binary(path) do
    %{state | new_line: parse_new_line_start(rest)}
  end

  defp parse_diff_line("+" <> _line, %{path: path, new_line: line, lines: lines} = state)
       when is_binary(path) and is_integer(line) do
    %{state | new_line: line + 1, lines: MapSet.put(lines, {path, line})}
  end

  defp parse_diff_line("-" <> _line, state), do: state

  defp parse_diff_line(" " <> _line, %{path: path, new_line: line, lines: lines} = state)
       when is_binary(path) and is_integer(line) do
    %{state | new_line: line + 1, lines: MapSet.put(lines, {path, line})}
  end

  defp parse_diff_line(_line, state), do: state

  defp parse_new_line_start(rest) do
    case Regex.run(~r/\+(\d+)(?:,\d+)?/, rest) do
      [_, value] -> String.to_integer(value)
      _missing -> nil
    end
  end

  defp valid_comment?(%{path: path, line: line, body: body} = comment, allowed_lines)
       when is_binary(path) and is_integer(line) and is_binary(body) do
    right_side_comment?(comment) and MapSet.member?(allowed_lines, {path, line})
  end

  defp valid_comment?(_comment, _allowed_lines), do: false

  defp right_side_comment?(%{side: side}) when side not in [nil, "RIGHT", :right], do: false
  defp right_side_comment?(%{body: body}) when is_binary(body), do: String.trim(body) != ""
  defp right_side_comment?(_comment), do: false

  defp to_github_comment(%{path: path, line: line, body: body}) do
    %{path: path, line: line, side: "RIGHT", body: body}
  end

  defp max_comments(opts) do
    value =
      Keyword.get(
        opts,
        :max_comments,
        Application.get_env(:symphony_elixir, :inline_review_max_comments, @default_max_comments)
      )

    case value do
      integer when is_integer(integer) and integer > 0 -> integer
      _other -> @default_max_comments
    end
  end
end
