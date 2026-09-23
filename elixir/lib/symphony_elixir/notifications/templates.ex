defmodule SymphonyElixir.Notifications.Templates do
  @moduledoc """
  Renders the first-detection e-mail alert for exactly one recipient.

  The alert carries only the priority, Jira key, project, a short title, the
  detection time and the Jira/Harmony links. Descriptions, analysis output,
  Linear links and credentials are never read from the input. Every header
  value is rejected when it contains control characters, and HTML is escaped.
  """

  alias Phoenix.HTML
  alias Swoosh.Email

  @queued_notice "Analiza została zakolejkowana. Naprawa nie została uruchomiona."
  @title_limit 120
  @header_fields ~w(delivery_id message_id_domain recipient from_email from_name priority_name jira_key project_name)a
  @required_fields (@header_fields -- [:from_name]) ++ [:title, :jira_url, :harmony_url]
  @domain_pattern ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+\z/
  @address_pattern ~r/
    \A[A-Za-z0-9._%+'-]+
    @[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?
    (?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+\z
  /x

  @type error ::
          :invalid_header_value
          | :invalid_address
          | :invalid_link
          | {:missing_field, atom()}

  @spec render_email(map()) :: {:ok, Email.t()} | {:error, error()}
  def render_email(attrs) when is_map(attrs) do
    with {:ok, fields} <- fetch_fields(attrs),
         :ok <- validate_header_values(fields),
         :ok <- validate_addresses(fields),
         :ok <- validate_links(fields) do
      {:ok, build_email(fields)}
    end
  end

  defp fetch_fields(attrs) do
    fields =
      Map.new([:from_name, :detected_at | @required_fields], fn key ->
        {key, Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))}
      end)
      |> Map.update!(:from_name, &(&1 || "Harmony"))

    cond do
      missing = Enum.find(@required_fields, &blank?(fields[&1])) -> {:error, {:missing_field, missing}}
      Ecto.UUID.cast(fields.delivery_id) == :error -> {:error, {:missing_field, :delivery_id}}
      not match?(%DateTime{}, fields.detected_at) -> {:error, {:missing_field, :detected_at}}
      true -> {:ok, fields}
    end
  end

  defp validate_header_values(fields) do
    if Enum.all?(@header_fields, &safe_header_value?(fields[&1])) do
      :ok
    else
      {:error, :invalid_header_value}
    end
  end

  defp validate_addresses(fields) do
    valid? =
      Regex.match?(@address_pattern, fields.recipient) and Regex.match?(@address_pattern, fields.from_email) and
        Regex.match?(@domain_pattern, fields.message_id_domain)

    if valid?, do: :ok, else: {:error, :invalid_address}
  end

  defp validate_links(fields) do
    if https_url?(fields.jira_url) and https_url?(fields.harmony_url), do: :ok, else: {:error, :invalid_link}
  end

  defp build_email(fields) do
    title = short_title(fields.title)
    detected_at = format_time(fields.detected_at)

    Email.new()
    |> Email.from({fields.from_name, fields.from_email})
    |> Email.to(fields.recipient)
    |> Email.subject("[Harmony] #{fields.priority_name} · #{fields.jira_key} · #{fields.project_name}")
    |> Email.header("Message-ID", "<harmony.#{fields.delivery_id}@#{fields.message_id_domain}>")
    |> Email.text_body(text_body(fields, title, detected_at))
    |> Email.html_body(html_body(fields, title, detected_at))
  end

  defp text_body(fields, title, detected_at) do
    """
    Nowa sprawa #{fields.jira_key} (#{fields.priority_name}) w projekcie #{fields.project_name}.

    Tytuł: #{title}
    Wykryto: #{detected_at}
    Jira: #{fields.jira_url}
    Harmony: #{fields.harmony_url}

    #{@queued_notice}
    """
  end

  defp html_body(fields, title, detected_at) do
    """
    <!DOCTYPE html>
    <html lang="pl">
    <body>
    <p>Nowa sprawa <strong>#{escape(fields.jira_key)}</strong> (#{escape(fields.priority_name)}) w projekcie #{escape(fields.project_name)}.</p>
    <p>Tytuł: #{escape(title)}<br>Wykryto: #{escape(detected_at)}</p>
    <p><a href="#{escape(fields.jira_url)}">Otwórz w Jira</a> · <a href="#{escape(fields.harmony_url)}">Otwórz w Harmony</a></p>
    <p>#{escape(@queued_notice)}</p>
    </body>
    </html>
    """
  end

  defp short_title(title) do
    normalized = title |> String.replace(~r/[[:cntrl:]\s]+/u, " ") |> String.trim()

    if String.length(normalized) > @title_limit do
      String.slice(normalized, 0, @title_limit - 1) <> "…"
    else
      normalized
    end
  end

  defp format_time(%DateTime{} = detected_at) do
    detected_at
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  defp escape(value), do: value |> HTML.html_escape() |> HTML.safe_to_string()

  defp safe_header_value?(value) when is_binary(value),
    do: String.valid?(value) and not Regex.match?(~r/[\x00-\x1F\x7F]/, value)

  defp safe_header_value?(_value), do: false

  defp https_url?(value) when is_binary(value) do
    uri = URI.parse(value)
    uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and safe_header_value?(value)
  end

  defp https_url?(_value), do: false

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
