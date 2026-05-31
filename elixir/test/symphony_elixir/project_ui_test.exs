defmodule SymphonyElixir.ProjectUiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_test_endpoint()
    :ok
  end

  @tag :db
  test "projects page lists configured projects" do
    :ok = checkout_repo(%{})

    {:ok, _project} =
      SymphonyElixir.Storage.upsert_project(%{
        slug: "portal",
        linear_project_slug: "portal-linear",
        linear_team_key: "COD",
        linear_human_review_state: "Human Review",
        github_owner: "dezet",
        github_repo: "portal",
        github_base_branch: "develop",
        config_version: 3,
        config: %{"review" => %{"trigger" => "@hreview"}}
      })

    {:ok, _view, html} = live(build_conn(), "/projects")

    assert html =~ "Projects"
    assert html =~ "portal"
    assert html =~ "dezet/portal"
    assert html =~ "portal-linear"
    assert html =~ "3"
  end

  @tag :db
  test "project form creates a project record" do
    :ok = checkout_repo(%{})

    {:ok, view, _html} = live(build_conn(), "/projects/new")

    view
    |> form("#project-form",
      project: %{
        slug: "admin",
        linear_project_slug: "admin-linear",
        linear_team_key: "ADM",
        linear_human_review_state: "Human Review",
        github_owner: "dezet",
        github_repo: "admin",
        github_base_branch: "main",
        config_version: "2",
        config_json: ~s({"review":{"trigger":"@hreview"}})
      }
    )
    |> render_submit()

    assert_redirect(view, "/projects")

    project = SymphonyElixir.Storage.get_project_by_slug("admin")
    assert project.github_repo == "admin"
    assert project.linear_project_slug == "admin-linear"
    assert project.config_version == 2
    assert get_in(project.config, ["review", "trigger"]) == "@hreview"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
