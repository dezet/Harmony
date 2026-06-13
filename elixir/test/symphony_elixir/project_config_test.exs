defmodule SymphonyElixir.ProjectConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProjectConfig.{Loader, Schema, Sync}

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

    assert {:ok, [config]} = Loader.load_dir(projects_dir)
    assert config.slug == "portal"
    assert config.forge.owner == "dezet"
  end

  test "parse/1 accepts a forge: section", _ do
    raw = %{
      "slug" => "portal",
      "linear" => %{
        "project_slug" => "portal-abc",
        "team_key" => "COD",
        "human_review_state" => "Human Review"
      },
      "forge" => %{
        "type" => "github",
        "owner" => "acme",
        "repo" => "portal",
        "base_branch" => "main",
        "base_url" => "https://github.example.com",
        "protected_branches" => ["main", "develop"]
      },
      "review" => %{"template_version" => 1}
    }

    assert {:ok, config} = Schema.parse(raw)
    assert config.forge.type == "github"
    assert config.forge.owner == "acme"
    assert config.forge.repo == "portal"
    assert config.forge.base_branch == "main"
    assert config.forge.base_url == "https://github.example.com"
    assert config.forge.protected_branches == ["main", "develop"]
  end

  test "parse/1 accepts a legacy github: section mapped to forge", _ do
    raw = %{
      "slug" => "portal",
      "linear" => %{
        "project_slug" => "portal-abc",
        "team_key" => "COD",
        "human_review_state" => "Human Review"
      },
      "github" => %{
        "owner" => "acme",
        "repo" => "portal",
        "base_branch" => "main",
        "protected_branches" => ["main"]
      },
      "review" => %{"template_version" => 1}
    }

    assert {:ok, config} = Schema.parse(raw)
    assert config.forge.type == "github"
    assert config.forge.owner == "acme"
    assert config.forge.repo == "portal"
    assert config.forge.base_branch == "main"
    assert config.forge.protected_branches == ["main"]
  end

  test "parse/1 defaults forge type to github when omitted", _ do
    raw = %{
      "slug" => "portal",
      "linear" => %{
        "project_slug" => "portal-abc",
        "team_key" => "COD",
        "human_review_state" => "Human Review"
      },
      "forge" => %{
        "owner" => "acme",
        "repo" => "portal",
        "base_branch" => "main"
      },
      "review" => %{"template_version" => 1}
    }

    assert {:ok, config} = Schema.parse(raw)
    assert config.forge.type == "github"
  end

  @tag :db
  test "syncs a single project yaml into storage", %{projects_dir: projects_dir} do
    project_file = Path.join(projects_dir, "portal.yaml")
    write_project_config!(project_file)

    :ok = checkout_repo(%{})

    assert {:ok, [project]} = Sync.sync_dir(projects_dir)
    assert project.slug == "portal"
    assert project.forge_base_branch == "develop"
  end

  @tag :db
  test "sync writes forge_* columns", %{projects_dir: projects_dir} do
    write_project_config!(Path.join(projects_dir, "portal.yaml"))

    :ok = checkout_repo(%{})

    assert {:ok, [project]} = Sync.sync_dir(projects_dir)
    # forge_* columns populated
    assert project.forge_type == "github"
    assert project.forge_owner == "dezet"
    assert project.forge_repo == "portal"
    assert project.forge_base_branch == "develop"
  end

  @tag :db
  test "syncs multiple project yaml files into storage", %{projects_dir: projects_dir} do
    write_project_config!(Path.join(projects_dir, "portal.yaml"),
      slug: "portal",
      github_repo: "portal",
      linear_project_slug: "portal-linear"
    )

    write_project_config!(Path.join(projects_dir, "admin.yaml"),
      slug: "admin",
      github_repo: "admin",
      linear_project_slug: "admin-linear"
    )

    :ok = checkout_repo(%{})

    assert {:ok, projects} = Sync.sync_dir(projects_dir)
    assert Enum.map(projects, & &1.slug) == ["admin", "portal"]
    assert Enum.map(projects, & &1.linear_project_slug) == ["admin-linear", "portal-linear"]
  end

  defp write_project_config!(project_file, opts \\ []) do
    slug = Keyword.get(opts, :slug, "portal")
    github_repo = Keyword.get(opts, :github_repo, "portal")
    linear_project_slug = Keyword.get(opts, :linear_project_slug, "portal-6d90492ea04f")

    File.write!(project_file, """
    slug: #{slug}
    linear:
      project_slug: #{linear_project_slug}
      team_key: COD
      human_review_state: Human Review
    github:
      owner: dezet
      repo: #{github_repo}
      base_branch: develop
    review:
      trigger: "@hreview"
      template_version: 1
    """)
  end
end
