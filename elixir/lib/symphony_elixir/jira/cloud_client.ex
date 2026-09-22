defmodule SymphonyElixir.Jira.CloudClient do
  @moduledoc "Read-only Jira Cloud REST client for intake and pickers."

  alias SymphonyElixir.Jira.Issue

  @page_size 100
  @api_prefix "/rest/api/3"
  @issue_fields ["summary", "description", "priority", "status", "created", "updated", "project"]

  @spec list_boards(keyword()) :: {:ok, [map()]} | {:error, map()}
  def list_boards(opts \\ []) do
    paginate_offset(opts, "/rest/agile/1.0/board", "values")
  end

  @spec list_filters(keyword()) :: {:ok, [map()]} | {:error, map()}
  def list_filters(opts \\ []) do
    paginate_offset(opts, "#{@api_prefix}/filter/search", "values")
  end

  @spec list_priorities(keyword()) :: {:ok, [map()]} | {:error, map()}
  def list_priorities(opts \\ []) do
    paginate_offset(opts, "#{@api_prefix}/priority/search", "values")
  end

  @spec list_comments(String.t(), keyword()) :: {:ok, [map()]} | {:error, map()}
  def list_comments(issue_id_or_key, opts \\ []) when is_binary(issue_id_or_key) do
    if valid_segment?(issue_id_or_key) do
      paginate_offset(opts, "#{@api_prefix}/issue/#{encode_segment(issue_id_or_key)}/comment", "comments")
    else
      malformed_request()
    end
  end

  @spec board_filter_id(String.t() | integer(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def board_filter_id(board_id, opts \\ []) do
    with {:ok, id} <- numeric_id(board_id),
         {:ok, response} <- request(opts, :get, "/rest/agile/1.0/board/#{id}/configuration"),
         {:ok, filter_id} <- parse_board_filter(response.body) do
      {:ok, filter_id}
    end
  end

  @spec search_board_issues(String.t() | integer(), [String.t() | integer()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, map()}
  def search_board_issues(board_id, priority_ids, opts \\ []) do
    with {:ok, filter_id} <- board_filter_id(board_id, opts),
         {:ok, jql} <- build_filter_jql(filter_id, priority_ids) do
      search_issues(jql, opts)
    end
  end

  @spec search_filter_issues(String.t() | integer(), [String.t() | integer()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, map()}
  def search_filter_issues(filter_id, priority_ids, opts \\ []) do
    with {:ok, id} <- numeric_id(filter_id),
         {:ok, jql} <- build_filter_jql(id, priority_ids) do
      search_issues(jql, opts)
    end
  end

  @spec search_issues(String.t(), keyword()) :: {:ok, [Issue.t()]} | {:error, map()}
  def search_issues(jql, opts \\ []) do
    if is_binary(jql) and byte_size(jql) > 0 do
      search_page(opts, jql, nil, [], MapSet.new())
    else
      malformed_request()
    end
  end

  defp build_filter_jql(filter_id, priority_ids) when is_list(priority_ids) and priority_ids != [] do
    with {:ok, safe_filter_id} <- numeric_id(filter_id),
         {:ok, safe_priority_ids} <- numeric_ids(priority_ids) do
      ids = Enum.join(safe_priority_ids, ", ")
      {:ok, "filter = #{safe_filter_id} AND priority in (#{ids}) AND statusCategory != Done ORDER BY key ASC"}
    end
  end

  defp build_filter_jql(_filter_id, _priority_ids), do: malformed_request()

  defp paginate_offset(opts, path, collection_key) do
    paginate_offset(opts, path, collection_key, 0, [], MapSet.new())
  end

  defp paginate_offset(opts, path, collection_key, start_at, acc, seen) do
    with false <- MapSet.member?(seen, start_at),
         {:ok, response} <- request(opts, :get, path, params: [startAt: start_at, maxResults: @page_size]),
         {:ok, values, next_start, done?} <- parse_offset_page(response.body, collection_key, start_at) do
      items = acc ++ values
      next_seen = MapSet.put(seen, start_at)

      if done? do
        {:ok, items}
      else
        paginate_offset(opts, path, collection_key, next_start, items, next_seen)
      end
    else
      true -> malformed_response()
      {:error, _reason} = error -> error
    end
  end

  defp search_page(opts, jql, token, acc, seen_tokens) do
    body = %{jql: jql, maxResults: @page_size, fields: @issue_fields}
    body = if is_binary(token), do: Map.put(body, :nextPageToken, token), else: body

    with {:ok, response} <- request(opts, :post, "#{@api_prefix}/search/jql", json: body),
         {:ok, issues, next_token} <- parse_search_page(response.body) do
      parsed =
        Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, values} ->
          case Issue.from_api(issue) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | values]}}
            {:error, _reason} -> {:halt, malformed_response()}
          end
        end)

      with {:ok, page} <- parsed do
        all = acc ++ Enum.reverse(page)

        cond do
          is_nil(next_token) -> {:ok, all}
          MapSet.member?(seen_tokens, next_token) -> malformed_response()
          true -> search_page(opts, jql, next_token, all, MapSet.put(seen_tokens, next_token))
        end
      end
    end
  end

  defp parse_search_page(%{"issues" => issues} = body) when is_list(issues) do
    next_token = Map.get(body, "nextPageToken")

    case {Map.get(body, "isLast"), next_token} do
      {true, nil} -> {:ok, issues, nil}
      {true, ""} -> {:ok, issues, nil}
      {false, token} when is_binary(token) and token != "" -> {:ok, issues, token}
      _ -> malformed_response()
    end
  end

  defp parse_search_page(_body), do: malformed_response()

  defp parse_offset_page(body, collection_key, requested_start) when is_map(body) do
    values = Map.get(body, collection_key)
    response_start = Map.get(body, "startAt", requested_start)
    page_size = Map.get(body, "maxResults", @page_size)

    cond do
      not is_list(values) ->
        malformed_response()

      not Enum.all?(values, &is_map/1) ->
        malformed_response()

      not is_integer(response_start) or response_start != requested_start ->
        malformed_response()

      not is_integer(page_size) or page_size <= 0 ->
        malformed_response()

      invalid_optional_integer?(body, "total") ->
        malformed_response()

      invalid_optional_boolean?(body, "isLast") ->
        malformed_response()

      values == [] and is_integer(Map.get(body, "total")) and Map.get(body, "total") > requested_start ->
        malformed_response()

      values == [] and Map.get(body, "isLast") != true and not is_integer(Map.get(body, "total")) ->
        malformed_response()

      true ->
        next_start = requested_start + page_size
        total = Map.get(body, "total")
        last = Map.get(body, "isLast")
        done? = last == true or (is_integer(total) and next_start >= total)
        {:ok, values, next_start, done?}
    end
  end

  defp parse_offset_page(_body, _collection_key, _requested_start), do: malformed_response()

  defp request(opts, method, path, request_options \\ []) do
    with {:ok, config} <- client_config(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
      timeout_ms = Keyword.get(opts, :timeout_ms, 15_000)

      request = [
        method: method,
        url: config.base_url <> path,
        headers: config.headers,
        redirect: false,
        receive_timeout: timeout_ms
      ]

      request = Keyword.merge(request, request_options)
      request = if Keyword.has_key?(request_options, :json), do: add_content_type(request), else: request

      case request_fun.(request) do
        {:ok, %{status: 200, body: _body} = response} -> {:ok, response}
        {:ok, %{status: 200}} -> malformed_response()
        {:ok, %{status: status} = response} when is_integer(status) -> http_error(status, response)
        {:error, reason} -> transport_error(reason)
        _other -> malformed_response()
      end
    end
  end

  defp add_content_type(request) do
    headers = Keyword.fetch!(request, :headers)
    Keyword.put(request, :headers, [{"content-type", "application/json"} | headers])
  end

  defp client_config(opts) do
    token = Keyword.get(opts, :token)

    if not nonempty_binary?(token) do
      {:error, %{kind: :invalid_configuration}}
    else
      case Keyword.get(opts, :auth_mode) do
        mode when mode in [:classic, "classic"] -> classic_config(opts, token)
        mode when mode in [:scoped, "scoped"] -> scoped_config(opts, token)
        _ -> {:error, %{kind: :invalid_configuration}}
      end
    end
  end

  defp classic_config(opts, token) do
    email = Keyword.get(opts, :account_email)
    site_url = Keyword.get(opts, :site_url)

    if nonempty_binary?(email) and valid_site_url?(site_url) do
      encoded_credentials = Base.encode64("#{email}:#{token}")
      {:ok, %{base_url: String.trim_trailing(site_url, "/"), headers: auth_headers("Basic #{encoded_credentials}")}}
    else
      {:error, %{kind: :invalid_configuration}}
    end
  end

  defp scoped_config(opts, token) do
    cloud_id = Keyword.get(opts, :cloud_id)

    if is_binary(cloud_id) and Regex.match?(~r/\A[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}\z/, cloud_id) do
      {:ok,
       %{
         base_url: "https://api.atlassian.com/ex/jira/#{cloud_id}",
         headers: auth_headers("Bearer #{token}")
       }}
    else
      {:error, %{kind: :invalid_configuration}}
    end
  end

  defp valid_site_url?(site_url) when is_binary(site_url) do
    uri = URI.parse(site_url)
    host = uri.host && String.downcase(uri.host)

    is_nil(uri.scheme) == false and String.downcase(uri.scheme) == "https" and
      is_binary(host) and Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.atlassian\.net\z/, host) and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
      uri.path in [nil, "", "/"] and uri.port in [nil, 443]
  rescue
    _error -> false
  end

  defp valid_site_url?(_site_url), do: false

  defp auth_headers(authorization) do
    [{"authorization", authorization}, {"accept", "application/json"}]
  end

  defp http_error(status, response) do
    {:error,
     %{
       kind: :http_status,
       status: status,
       retry_after: if(status == 429, do: response |> response_header("retry-after") |> first_header_value(), else: nil)
     }}
  end

  defp transport_error(:timeout), do: {:error, %{kind: :timeout}}
  defp transport_error(%{reason: :timeout}), do: {:error, %{kind: :timeout}}
  defp transport_error(_reason), do: {:error, %{kind: :transport_error}}

  defp parse_board_filter(%{"filter" => %{"id" => id}}) do
    case numeric_id(id) do
      {:ok, safe_id} -> {:ok, safe_id}
      {:error, _reason} -> malformed_response()
    end
  end

  defp parse_board_filter(_body), do: malformed_response()

  defp numeric_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case numeric_id(id) do
        {:ok, safe_id} -> {:cont, {:ok, [safe_id | acc]}}
        {:error, _reason} -> {:halt, malformed_request()}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp numeric_id(id) when is_integer(id) and id > 0, do: {:ok, Integer.to_string(id)}

  defp numeric_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9]+\z/, id) and String.to_integer(id) > 0, do: {:ok, id}, else: malformed_request()
  end

  defp numeric_id(_id), do: malformed_request()

  defp valid_segment?(value), do: value != "" and not String.contains?(value, ["/", "\\", "?", "#"])
  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp nonempty_binary?(value) do
    is_binary(value) and String.trim(value) != "" and not String.contains?(value, ["\r", "\n"])
  end

  defp invalid_optional_integer?(map, key) do
    Map.has_key?(map, key) and not is_integer(Map.get(map, key))
  end

  defp invalid_optional_boolean?(map, key) do
    Map.has_key?(map, key) and not is_boolean(Map.get(map, key))
  end

  defp response_header(response, name) do
    headers = Map.get(response, :headers, %{})

    case headers do
      headers when is_map(headers) ->
        Enum.find_value(headers, fn {key, value} ->
          if String.downcase(to_string(key)) == name, do: value
        end)

      headers when is_list(headers) ->
        Enum.find_value(headers, fn {key, value} -> if String.downcase(to_string(key)) == name, do: value end)

      _ ->
        nil
    end
  end

  defp first_header_value([value | _]) when is_binary(value), do: value
  defp first_header_value(value) when is_binary(value), do: value
  defp first_header_value(_value), do: nil

  defp malformed_request, do: {:error, %{kind: :invalid_request}}
  defp malformed_response, do: {:error, %{kind: :malformed_response}}
end
