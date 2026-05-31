defmodule SymphonyElixir.WorkRun do
  @moduledoc """
  Normalized unit of work dispatched by the orchestrator.
  """

  alias SymphonyElixir.Linear.Issue

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :project_slug,
    :type,
    :status,
    :dedupe_key,
    :github_owner,
    :github_repo,
    :github_pr_number,
    :github_head_sha,
    :github_head_ref,
    :github_base_ref,
    :linear_issue_id,
    :linear_identifier,
    :linear_url,
    :agent_backend,
    payload: %{},
    required_evidence: []
  ]

  @spec from_linear_issue(Issue.t(), keyword()) :: t()
  def from_linear_issue(%Issue{} = issue, opts) when is_list(opts) do
    required_evidence = opts |> Keyword.get(:required_evidence, []) |> List.wrap()

    payload =
      %{issue: issue}
      |> maybe_put_payload(:project_id, Keyword.get(opts, :project_id))

    %__MODULE__{
      project_slug: Keyword.get(opts, :project_slug) || issue.project_slug,
      type: "implementation",
      status: "queued",
      dedupe_key: "linear:#{issue.id}",
      github_base_ref: Keyword.get(opts, :base_branch),
      linear_issue_id: issue.id,
      linear_identifier: issue.identifier,
      linear_url: issue.url,
      agent_backend: "codex",
      payload:
        payload
        |> maybe_put_payload(:config_version, Keyword.get(opts, :config_version))
        |> maybe_put_payload(:required_evidence, required_evidence),
      required_evidence: required_evidence
    }
  end

  defp maybe_put_payload(payload, _key, nil), do: payload
  defp maybe_put_payload(payload, key, value), do: Map.put(payload, key, value)
end
