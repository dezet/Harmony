defmodule SymphonyElixir.Jira.Adf do
  @moduledoc "Converts Jira ADF descriptions to bounded plain text."

  @max_bytes 100 * 1024
  @truncation_marker "[opis skrócono]"

  @spec to_text(term()) :: String.t()
  def to_text(document) do
    document
    |> render_node()
    |> truncate()
  end

  defp render_node(nil), do: ""
  defp render_node(text) when is_binary(text), do: text
  defp render_node(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &render_node/1)

  defp render_node(%{"type" => "doc", "content" => content}) when is_list(content) do
    render_blocks(content)
  end

  defp render_node(%{"type" => "paragraph", "content" => content}) when is_list(content) do
    Enum.map_join(content, "", &render_node/1)
  end

  defp render_node(%{"type" => "bulletList", "content" => content}) when is_list(content) do
    content
    |> Enum.map(&render_list_item/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map_join("\n", &"• #{&1}")
  end

  defp render_node(%{"type" => "orderedList", "content" => content} = node) when is_list(content) do
    start =
      case get_in(node, ["attrs", "order"]) do
        order when is_integer(order) and order > 0 -> order
        _ -> 1
      end

    content
    |> Enum.map(&render_list_item/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.with_index(start)
    |> Enum.map_join("\n", fn {text, index} -> "#{index}. #{text}" end)
  end

  defp render_node(%{"type" => "listItem", "content" => content}) when is_list(content) do
    render_blocks(content)
  end

  defp render_node(%{"type" => "codeBlock", "content" => content}) when is_list(content) do
    Enum.map_join(content, "", &render_node/1)
  end

  defp render_node(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp render_node(%{"type" => "hardBreak"}), do: "\n"

  defp render_node(%{"type" => "emoji"} = node) do
    attrs = node |> Map.get("attrs") |> attrs_map()
    Map.get(attrs, "fallback") || Map.get(attrs, "text") || ""
  end

  defp render_node(%{"type" => "mention"} = node) do
    attrs = node |> Map.get("attrs") |> attrs_map()
    Map.get(attrs, "text") || ""
  end

  defp render_node(%{"content" => content}) when is_list(content), do: render_blocks(content)
  defp render_node(%{"text" => text}) when is_binary(text), do: text
  defp render_node(_unknown), do: ""

  defp render_blocks(nodes) do
    nodes
    |> Enum.map(&render_node/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp render_list_item(%{"type" => "listItem"} = node), do: render_node(node)
  defp render_list_item(node), do: render_node(node)

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(_attrs), do: %{}

  defp truncate(text) when byte_size(text) <= @max_bytes, do: text

  defp truncate(text) do
    content_limit = @max_bytes - byte_size(@truncation_marker) - 1
    prefix = truncate_utf8(text, content_limit)

    separator = if String.ends_with?(prefix, "\n"), do: "", else: "\n"
    prefix <> separator <> @truncation_marker
  end

  defp truncate_utf8(text, max_bytes), do: do_truncate_utf8(text, max_bytes, 0, [])

  defp do_truncate_utf8(<<>>, _max_bytes, _bytes, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_truncate_utf8(text, max_bytes, bytes, acc) do
    case String.next_codepoint(text) do
      {codepoint, rest} when bytes + byte_size(codepoint) <= max_bytes ->
        do_truncate_utf8(rest, max_bytes, bytes + byte_size(codepoint), [codepoint | acc])

      _ ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
