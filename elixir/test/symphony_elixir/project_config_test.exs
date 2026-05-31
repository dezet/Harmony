defmodule SymphonyElixir.ProjectConfigTest do
  use SymphonyElixir.TestSupport

  setup do
    root = Path.join(System.tmp_dir!(), "harmony-project-config-#{System.unique_integer([:positive])}")
    projects_dir = Path.join(root, "projects")
    File.mkdir_p!(projects_dir)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, projects_dir: projects_dir}
  end

  test "loads a single project yaml", %{projects_dir: projects_dir} do
    project_file = Path.join(projects_dir, "portal.yaml")
    write_project_config!(project_file)

    assert {:ok, [config]} = SymphonyElixir.ProjectConfig.Loader.load_dir(projects_dir)
    assert config.slug == "portal"
    assert config.github.owner == "dezet"
  end

  @tag :db
  test "syncs a single project yaml into storage", %{projects_dir: projects_dir} do
    project_file = Path.join(projects_dir, "portal.yaml")
    write_project_config!(project_file)

    :ok = checkout_repo(%{})

    assert {:ok, [project]} = SymphonyElixir.ProjectConfig.Sync.sync_dir(projects_dir)
    assert project.slug == "portal"
    assert project.github_base_branch == "develop"
  end

  defp write_project_config!(project_file) do
    File.write!(project_file, """
    slug: portal
    linear:
      project_slug: portal-6d90492ea04f
      team_key: COD
      human_review_state: Human Review
    github:
      owner: dezet
      repo: portal
      base_branch: develop
    review:
      trigger: "@hreview"
      template_version: 1
    """)
  end
end
