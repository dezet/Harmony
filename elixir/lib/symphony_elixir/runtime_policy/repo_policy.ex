defmodule SymphonyElixir.RuntimePolicy.RepoPolicy do
  @moduledoc """
  Repository safety policy for PR branch writes.
  """

  @spec authorize_push(map()) :: :ok | {:error, atom()}
  def authorize_push(%{} = pr) do
    head_repo = Map.get(pr, :head_repo_full_name)
    base_repo = Map.get(pr, :base_repo_full_name)
    head_ref = Map.get(pr, :head_ref)
    base_ref = Map.get(pr, :base_ref)
    protected = Map.get(pr, :protected_branches, [])

    cond do
      head_repo != base_repo ->
        {:error, :fork_pr_requires_repair_branch}

      head_ref == base_ref ->
        {:error, :base_branch_push_forbidden}

      head_ref in protected ->
        {:error, :protected_branch_push_forbidden}

      true ->
        :ok
    end
  end
end
