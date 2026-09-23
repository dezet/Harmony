defmodule SymphonyElixir.Forge.ArchiveRedirect do
  @moduledoc false

  @redirect_statuses [301, 302, 303, 307, 308]
  @max_redirects 5

  @spec fetch(keyword(), (keyword() -> {:ok, term()} | {:error, term()}), atom()) ::
          {:ok, term()} | {:error, term()}
  def fetch(request_opts, request_fun, stream_key)
      when is_list(request_opts) and is_function(request_fun, 1) and is_atom(stream_key) do
    with {:ok, url} <- validate_https_url(Keyword.fetch!(request_opts, :url)) do
      do_fetch(request_opts, request_fun, stream_key, url, 0)
    end
  end

  defp do_fetch(request_opts, request_fun, stream_key, url, redirects) do
    request_opts = request_opts |> Keyword.put(:url, url) |> Keyword.put(:redirect, false)

    case request_fun.(request_opts) do
      {:ok, response} = result ->
        cond do
          response_too_large?(response, stream_key) ->
            result

          response.status in @redirect_statuses and redirects >= @max_redirects ->
            {:error, :archive_redirect_limit_exceeded}

          response.status in @redirect_statuses ->
            follow_redirect(response, request_opts, request_fun, stream_key, url, redirects)

          true ->
            result
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_redirect(response, request_opts, request_fun, stream_key, current_url, redirects) do
    with {:ok, location} <- response_location(response),
         {:ok, redirect_url} <- resolve_redirect(current_url, location) do
      next_opts =
        request_opts
        |> Keyword.delete(:params)
        |> Keyword.put(:headers, safe_redirect_headers(Keyword.get(request_opts, :headers, [])))

      do_fetch(next_opts, request_fun, stream_key, redirect_url, redirects + 1)
    end
  end

  defp response_too_large?(%{private: private}, stream_key) when is_map(private) do
    case Map.get(private, stream_key) do
      %{too_large?: true} -> true
      _other -> false
    end
  end

  defp response_too_large?(_response, _stream_key), do: false

  defp response_location(%{headers: headers}) when is_map(headers) do
    location = Map.get(headers, "location") || Map.get(headers, "Location")

    case location do
      [value | _rest] when is_binary(value) -> {:ok, value}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, :invalid_archive_redirect}
    end
  end

  defp response_location(_response), do: {:error, :invalid_archive_redirect}

  defp resolve_redirect(current_url, location) when is_binary(location) and location != "" do
    with :ok <- validate_uri_syntax(location),
         merged_uri = URI.merge(URI.parse(current_url), location),
         {:ok, validated_uri} <- validate_https_uri(merged_uri) do
      {:ok, URI.to_string(validated_uri)}
    end
  rescue
    ArgumentError -> {:error, :invalid_archive_redirect}
  end

  defp resolve_redirect(_current_url, _location), do: {:error, :invalid_archive_redirect}

  defp validate_https_url(url) when is_binary(url) do
    with :ok <- validate_uri_syntax(url),
         {:ok, uri} <- url |> URI.parse() |> validate_https_uri() do
      {:ok, URI.to_string(uri)}
    end
  rescue
    ArgumentError -> {:error, :invalid_archive_redirect}
  end

  defp validate_https_url(_url), do: {:error, :invalid_archive_redirect}

  defp validate_uri_syntax(url) do
    if String.valid?(url) do
      url |> :uri_string.parse() |> validate_uri_port()
    else
      {:error, :invalid_archive_redirect}
    end
  end

  defp validate_uri_port(parsed) when is_map(parsed) do
    case Map.fetch(parsed, :port) do
      :error -> :ok
      {:ok, port} when is_integer(port) and port in 1..65_535 -> :ok
      _other -> {:error, :invalid_archive_redirect}
    end
  end

  defp validate_uri_port(_parsed), do: {:error, :invalid_archive_redirect}

  defp validate_https_uri(uri) do
    cond do
      uri.scheme != "https" -> {:error, :insecure_archive_redirect}
      is_nil(uri.host) or uri.host == "" -> {:error, :invalid_archive_redirect}
      not is_nil(uri.userinfo) -> {:error, :invalid_archive_redirect}
      not is_nil(uri.fragment) -> {:error, :invalid_archive_redirect}
      not valid_uri_host_and_port?(uri) -> {:error, :invalid_archive_redirect}
      true -> {:ok, uri}
    end
  end

  defp valid_uri_host_and_port?(%URI{host: host, port: port}) when is_binary(host) do
    String.valid?(host) and valid_host?(host) and valid_port?(port)
  end

  defp valid_uri_host_and_port?(_uri), do: false

  defp valid_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> true
      {:error, _reason} -> valid_dns_name?(host)
    end
  rescue
    ArgumentError -> false
  end

  defp valid_dns_name?(host) do
    host = String.trim_trailing(host, ".")
    labels = String.split(host, ".")

    String.length(host) in 1..253 and
      Enum.all?(labels, fn label ->
        String.length(label) in 1..63 and
          String.match?(label, ~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\z/)
      end)
  end

  defp valid_port?(port) when is_integer(port) and port in 1..65_535, do: true
  defp valid_port?(_port), do: false

  defp safe_redirect_headers(headers) do
    Enum.filter(headers, fn
      {name, _value} when is_binary(name) -> String.downcase(name) == "accept"
      _other -> false
    end)
  end
end
