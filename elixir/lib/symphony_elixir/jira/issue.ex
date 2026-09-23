defmodule SymphonyElixir.Jira.Issue do
  @moduledoc "Normalized Jira issue fields used by intake polling."

  alias SymphonyElixir.Jira.Adf

  defstruct [
    :id,
    :key,
    :summary,
    :description,
    :priority_id,
    :priority_name,
    :status_id,
    :status_name,
    :status_category,
    :created,
    :updated,
    :project_id,
    :project_key,
    :project_name
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          key: String.t() | nil,
          summary: String.t() | nil,
          description: String.t() | nil,
          priority_id: String.t() | nil,
          priority_name: String.t() | nil,
          status_id: String.t() | nil,
          status_name: String.t() | nil,
          status_category: String.t() | nil,
          created: String.t() | nil,
          updated: String.t() | nil,
          project_id: String.t() | nil,
          project_key: String.t() | nil,
          project_name: String.t() | nil
        }

  @required_fields ["summary", "description", "priority", "status", "created", "updated", "project"]

  @spec from_api(term()) :: {:ok, t()} | {:error, :malformed_issue}
  def from_api(%{"id" => id, "key" => key, "fields" => fields})
      when ((is_binary(id) and byte_size(id) > 0) or (is_integer(id) and id > 0)) and is_binary(key) and
             byte_size(key) > 0 and is_map(fields) do
    if valid_issue_fields?(fields) do
      {:ok, build_issue(id, key, fields)}
    else
      {:error, :malformed_issue}
    end
  end

  def from_api(_), do: {:error, :malformed_issue}

  @spec browse_url(t(), String.t()) :: String.t()
  def browse_url(%__MODULE__{key: key}, site_url) when is_binary(key) and is_binary(site_url) do
    "#{String.trim_trailing(site_url, "/")}/browse/#{URI.encode(key, &URI.char_unreserved?/1)}"
  end

  defp valid_issue_fields?(fields) do
    Enum.all?(@required_fields, &Map.has_key?(fields, &1)) and valid_fields?(fields)
  end

  defp build_issue(id, key, fields) do
    priority = fields["priority"] || %{}
    status = fields["status"] || %{}
    category = if is_map(status["statusCategory"]), do: status["statusCategory"], else: %{}
    project = fields["project"] || %{}

    %__MODULE__{
      id: to_string(id),
      key: key,
      summary: fields["summary"],
      description: Adf.to_text(fields["description"]),
      priority_id: optional_string(priority["id"]),
      priority_name: optional_string(priority["name"]),
      status_id: optional_string(status["id"]),
      status_name: optional_string(status["name"]),
      status_category: optional_string(category["key"]),
      created: fields["created"],
      updated: fields["updated"],
      project_id: optional_string(project["id"]),
      project_key: optional_string(project["key"]),
      project_name: optional_string(project["name"])
    }
  end

  defp valid_fields?(fields) do
    valid_text?(fields["summary"]) and valid_adf?(fields["description"]) and
      valid_object_or_nil?(fields["priority"]) and valid_object_or_nil?(fields["status"]) and
      valid_text_or_nil?(fields["created"]) and valid_text_or_nil?(fields["updated"]) and
      valid_object_or_nil?(fields["project"])
  end

  defp valid_text?(value), do: is_binary(value)
  defp valid_text_or_nil?(value), do: is_binary(value) or is_nil(value)
  defp valid_adf?(value), do: is_binary(value) or is_map(value) or is_nil(value)
  defp valid_object_or_nil?(value), do: is_map(value) or is_nil(value)

  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(_value), do: nil
end
