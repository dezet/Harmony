defmodule SymphonyElixir.Repo.Migrations.AddPrLinkBranchRefs do
  use Ecto.Migration

  def change do
    alter table(:pull_request_links) do
      add(:github_head_ref, :text)
      add(:github_base_ref, :text)
    end
  end
end
