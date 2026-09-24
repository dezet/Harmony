defmodule SymphonyElixir.Notifications.Templates do
  @moduledoc """
  Renders the first-detection e-mail and SMS alerts for exactly one recipient.

  The e-mail carries only the priority, Jira key, project, a short title, the
  detection time and the Jira/Harmony links. Descriptions, analysis output,
  Linear links and credentials are never read from the input. Every header
  value is rejected when it contains control characters, and HTML is escaped.

  The SMS carries only the Jira key, priority and Harmony case link. It is
  limited to 134 UTF-16 units (two Unicode segments); a longer message is a
  validation error, never a truncated link.

  Operator test-sends use fixed texts that carry no case data: the test e-mail
  has only the sender, one recipient and a Message-ID stable per delivery.
  """

  alias Phoenix.HTML
  alias Swoosh.Email

  @queued_notice "Analiza została zakolejkowana. Naprawa nie została uruchomiona."
  @sms_unit_limit 134
  @sms_fields [:jira_key, :priority_name, :case_url]
  @test_sms "Harmony: wiadomość testowa SMSAPI. Nie wymaga działania."
  @test_email_subject "[Harmony] Wiadomość testowa"
  @test_email_text "To jest wiadomość testowa Harmony wysłana przez operatora. Nie wymaga działania."
  @test_email_fields ~w(delivery_id message_id_domain recipient from_email)a
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
          | :message_too_long
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

  @spec render_sms(map()) :: {:ok, String.t()} | {:error, error()}
  def render_sms(attrs) when is_map(attrs) do
    fields = Map.new(@sms_fields, fn key -> {key, Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))} end)

    cond do
      missing = Enum.find(@sms_fields, &blank?(fields[&1])) -> {:error, {:missing_field, missing}}
      not Enum.all?(@sms_fields, &safe_header_value?(fields[&1])) -> {:error, :invalid_header_value}
      not https_url?(fields.case_url) -> {:error, :invalid_link}
      true -> within_sms_limit("Harmony: #{fields.jira_key}, #{fields.priority_name}. Nowa sprawa: #{fields.case_url}")
    end
  end

  @spec render_test_email(map()) :: {:ok, Email.t()} | {:error, error()}
  def render_test_email(attrs) when is_map(attrs) do
    fields =
      Map.new([:from_name | @test_email_fields], fn key -> {key, Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))} end)
      |> Map.update!(:from_name, &(&1 || "Harmony"))

    cond do
      missing = Enum.find(@test_email_fields, &blank?(fields[&1])) -> {:error, {:missing_field, missing}}
      Ecto.UUID.cast(fields.delivery_id) == :error -> {:error, {:missing_field, :delivery_id}}
      not Enum.all?([:from_name | @test_email_fields], &safe_header_value?(fields[&1])) -> {:error, :invalid_header_value}
      true -> with :ok <- validate_addresses(fields), do: {:ok, build_test_email(fields)}
    end
  end

  @spec render_test_sms() :: String.t()
  def render_test_sms, do: @test_sms

  @spec sms_unit_limit() :: pos_integer()
  def sms_unit_limit, do: @sms_unit_limit

  @spec sms_units(String.t()) :: non_neg_integer()
  def sms_units(text) when is_binary(text) do
    text |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)
  end

  @spec case_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_link}
  def case_url(public_url, case_id) when is_binary(public_url) and is_binary(case_id) do
    base = String.trim(public_url)
    uri = URI.parse(base)

    if https_url?(base) and is_nil(uri.query) and is_nil(uri.fragment) and match?({:ok, _uuid}, Ecto.UUID.cast(case_id)) do
      url = URI.merge(String.trim_trailing(base, "/") <> "/", "/cases/jira_#{case_id}")
      {:ok, URI.to_string(url)}
    else
      {:error, :invalid_link}
    end
  end

  defp within_sms_limit(message) do
    if sms_units(message) <= @sms_unit_limit, do: {:ok, message}, else: {:error, :message_too_long}
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

  defp build_test_email(fields) do
    Email.new()
    |> Email.from({fields.from_name, fields.from_email})
    |> Email.to(fields.recipient)
    |> Email.subject(@test_email_subject)
    |> Email.header("Message-ID", "<harmony.#{fields.delivery_id}@#{fields.message_id_domain}>")
    |> Email.text_body(@test_email_text <> "\n")
    |> Email.html_body("<!DOCTYPE html>\n<html lang=\"pl\">\n<body>\n<p>#{escape(@test_email_text)}</p>\n</body>\n</html>\n")
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
