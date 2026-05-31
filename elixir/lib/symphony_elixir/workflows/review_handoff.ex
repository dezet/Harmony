defmodule SymphonyElixir.Workflows.ReviewHandoff do
  @moduledoc """
  Publishes requested GitHub PR review output.
  """

  alias SymphonyElixir.{Github, WorkRun}

  @processed_marker "harmony-review-processed"

  @spec publish(WorkRun.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def publish(%WorkRun{} = run, body, opts \\ []) when is_binary(body) do
    create_review = Keyword.get(opts, :create_review, &Github.Client.create_pull_request_review/5)

    create_review.(
      run.github_owner,
      run.github_repo,
      run.github_pr_number,
      body_with_processed_marker(body, run),
      event: "COMMENT"
    )
  end

  defp body_with_processed_marker(body, %WorkRun{} = run) do
    """
    #{body}

    <!-- #{@processed_marker}: #{run.dedupe_key || "unknown"} -->
    """
  end
end
