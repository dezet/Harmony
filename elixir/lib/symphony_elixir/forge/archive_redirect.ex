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
    try do
      merged_uri = URI.merge(URI.parse(current_url), location)

      with {:ok, _validated_uri} <- validate_https_uri(merged_uri) do
        {:ok, URI.to_string(merged_uri)}
      end
    rescue
      ArgumentError -> {:error, :invalid_archive_redirect}
    end
  end

  defp resolve_redirect(_current_url, _location), do: {:error, :invalid_archive_redirect}

  defp validate_https_url(url) when is_binary(url) do
    url
    |> URI.parse()
    |> validate_https_uri()
    |> case do
      {:ok, uri} -> {:ok, URI.to_string(uri)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:error, :invalid_archive_redirect}
  end

  defp validate_https_url(_url), do: {:error, :invalid_archive_redirect}

  defp validate_https_uri(uri) do
    cond do
      uri.scheme != "https" -> {:error, :insecure_archive_redirect}
      is_nil(uri.host) or uri.host == "" -> {:error, :invalid_archive_redirect}
      not is_nil(uri.userinfo) -> {:error, :invalid_archive_redirect}
      not is_nil(uri.fragment) -> {:error, :invalid_archive_redirect}
      not valid_authority?(uri) -> {:error, :invalid_archive_redirect}
      true -> {:ok, uri}
    end
  end

  defp valid_authority?(%URI{host: host, authority: authority, port: port})
       when is_binary(host) and is_binary(authority) do
    with true <- String.valid?(host),
         true <- valid_host?(host),
         {:ok, authority_port} <- authority_port(authority, host),
         true <- valid_port?(authority_port, port) do
      true
    else
      _other -> false
    end
  end

  defp valid_authority?(_uri), do: false

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

  defp authority_port(authority, host) do
    host_in_authority = if String.contains?(host, ":"), do: "[#{host}]", else: host

    case String.split(authority, host_in_authority, parts: 2) do
      ["", ""] -> {:ok, nil}
      ["", ":" <> port] -> parse_port(port)
      _other -> :error
    end
  end

  defp parse_port(port) do
    case Integer.parse(port) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _other -> :error
    end
  end

  defp valid_port?(nil, 443), do: true
  defp valid_port?(authority_port, authority_port), do: true
  defp valid_port?(_authority_port, _uri_port), do: false

  defp safe_redirect_headers(headers) do
    Enum.filter(headers, fn
      {name, _value} when is_binary(name) -> String.downcase(name) == "accept"
      _other -> false
    end)
  end
end
