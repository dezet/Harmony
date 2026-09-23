defmodule SymphonyElixir.Intake.AnalysisPolicy do
  @moduledoc """
  Builds the fixed Codex session policy used for read-only Jira analysis.
  """

  @type t :: %{
          approval_policy: String.t(),
          app_config: map(),
          dynamic_tools: [],
          effort: String.t(),
          model: String.t(),
          output_schema: map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @output_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => [
      "summary",
      "facts",
      "hypotheses",
      "missing_data",
      "next_steps",
      "needs_input",
      "context_scope"
    ],
    "properties" => %{
      "summary" => %{"type" => "string", "maxLength" => 2000},
      "facts" => %{
        "type" => "array",
        "maxItems" => 20,
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["text", "source"],
          "properties" => %{
            "text" => %{"type" => "string", "maxLength" => 1000},
            "source" => %{"type" => "string", "maxLength" => 1000}
          }
        }
      },
      "hypotheses" => %{
        "type" => "array",
        "maxItems" => 20,
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["text", "confidence", "evidence"],
          "properties" => %{
            "text" => %{"type" => "string", "maxLength" => 1000},
            "confidence" => %{"type" => "string", "enum" => ["low", "medium", "high"]},
            "evidence" => %{
              "type" => "array",
              "maxItems" => 20,
              "items" => %{"type" => "string", "maxLength" => 1000}
            }
          }
        }
      },
      "missing_data" => %{
        "type" => "array",
        "maxItems" => 20,
        "items" => %{"type" => "string", "maxLength" => 1000}
      },
      "next_steps" => %{
        "type" => "array",
        "maxItems" => 20,
        "items" => %{"type" => "string", "maxLength" => 1000}
      },
      "needs_input" => %{"type" => "boolean"},
      "context_scope" => %{"type" => "string", "enum" => ["issue_only", "issue_and_repository"]}
    }
  }

  @analysis_app_config %{
    "mcp_servers" => %{},
    "project_doc_max_bytes" => 0,
    "web_search" => "disabled",
    "shell_environment_policy" => %{
      "ignore_default_excludes" => false,
      "filters" => %{
        "PATH" => "include",
        "HOME" => "include",
        "TMPDIR" => "include"
      }
    },
    "features" => %{
      "apps" => false,
      "browser_use" => false,
      "browser_use_external" => false,
      "browser_use_full_cdp_access" => false,
      "hooks" => false,
      "multi_agent" => false,
      "plugins" => false,
      "remote_plugin" => false,
      "shell_tool" => true,
      "skill_mcp_dependency_install" => false,
      "skip_host_skill_discovery" => true
    }
  }

  @doc "Builds the only supported policy for an analysis session."
  @spec build(map()) :: {:ok, t()} | {:error, term()}
  def build(options) when is_map(options) do
    normalized_options = normalize_options(options)
    unknown_fields = Map.keys(normalized_options) -- [:model, :effort]

    cond do
      unknown_fields != [] ->
        {:error, {:unsupported_analysis_policy_fields, Enum.sort(unknown_fields)}}

      not valid_text?(Map.get(normalized_options, :model)) ->
        {:error, :analysis_model_required}

      not valid_text?(Map.get(normalized_options, :effort)) ->
        {:error, :analysis_effort_required}

      true ->
        {:ok,
         %{
           approval_policy: "on-request",
           app_config: @analysis_app_config,
           dynamic_tools: [],
           effort: Map.fetch!(normalized_options, :effort),
           model: Map.fetch!(normalized_options, :model),
           output_schema: @output_schema,
           thread_sandbox: "read-only",
           turn_sandbox_policy: %{
             "type" => "readOnly",
             "networkAccess" => false,
             "access" => %{
               "type" => "restricted",
               "includePlatformDefaults" => true,
               "readableRoots" => []
             }
           }
         }}
    end
  end

  def build(_options), do: {:error, :invalid_analysis_policy}

  @doc "Creates a private Codex home that contains no inherited user configuration."
  @spec prepare_runtime() :: {:ok, map()} | {:error, term()}
  def prepare_runtime do
    runtime_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-analysis-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    home = Path.join(runtime_root, "home")
    codex_home = Path.join(runtime_root, "codex")
    xdg_config_home = Path.join(runtime_root, "xdg-config")
    xdg_cache_home = Path.join(runtime_root, "xdg-cache")
    xdg_data_home = Path.join(runtime_root, "xdg-data")
    tmp_dir = Path.join(runtime_root, "tmp")

    with :ok <- File.mkdir_p(runtime_root),
         :ok <- File.chmod(runtime_root, 0o700),
         :ok <- create_private_dirs([home, codex_home, xdg_config_home, xdg_cache_home, xdg_data_home, tmp_dir]),
         :ok <- copy_auth_file(codex_home),
         :ok <- write_codex_config(codex_home) do
      {:ok,
       %{
         root: runtime_root,
         home: home,
         codex_home: codex_home,
         port_environment:
           port_environment(%{
             "HOME" => home,
             "CODEX_HOME" => codex_home,
             "XDG_CONFIG_HOME" => xdg_config_home,
             "XDG_CACHE_HOME" => xdg_cache_home,
             "XDG_DATA_HOME" => xdg_data_home,
             "TMPDIR" => tmp_dir
           })
       }}
    else
      {:error, reason} ->
        File.rm_rf(runtime_root)
        {:error, {:analysis_runtime_setup_failed, reason}}
    end
  end

  @doc "Removes a private analysis runtime created by `prepare_runtime/0`."
  @spec cleanup_runtime(map() | nil) :: :ok
  def cleanup_runtime(%{root: root}) when is_binary(root) do
    File.rm_rf(root)
    :ok
  end

  def cleanup_runtime(_runtime), do: :ok

  defp normalize_options(options) do
    Enum.reduce(options, %{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when key in [:model, :effort], do: key
  defp normalize_key("model"), do: :model
  defp normalize_key("effort"), do: :effort
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: key

  defp valid_text?(value), do: is_binary(value) and String.trim(value) != ""

  defp create_private_dirs(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.mkdir_p(path) do
        :ok ->
          case File.chmod(path, 0o700) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:chmod_failed, path, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:mkdir_failed, path, reason}}}
      end
    end)
  end

  defp copy_auth_file(codex_home) do
    source_codex_home =
      System.get_env("CODEX_HOME") || Path.join(System.get_env("HOME") || System.user_home!(), ".codex")

    source_auth = Path.join(source_codex_home, "auth.json")
    target_auth = Path.join(codex_home, "auth.json")

    if File.regular?(source_auth) do
      with :ok <- File.cp(source_auth, target_auth),
           :ok <- File.chmod(target_auth, 0o600) do
        :ok
      end
    else
      :ok
    end
  end

  defp write_codex_config(codex_home) do
    path = Path.join(codex_home, "config.toml")

    with :ok <- File.write(path, codex_config()),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp codex_config do
    """
    approval_policy = "on-request"
    sandbox_mode = "read-only"
    project_doc_max_bytes = 0
    web_search = "disabled"
    mcp_servers = {}

    [shell_environment_policy]
    ignore_default_excludes = false

    [shell_environment_policy.filters]
    PATH = "include"
    HOME = "include"
    TMPDIR = "include"

    [features]
    apps = false
    browser_use = false
    browser_use_external = false
    browser_use_full_cdp_access = false
    hooks = false
    multi_agent = false
    plugins = false
    remote_plugin = false
    shell_tool = true
    skill_mcp_dependency_install = false
    skip_host_skill_discovery = true
    """
  end

  defp port_environment(runtime_values) do
    inherited_names = System.get_env() |> Map.keys() |> Enum.uniq()

    allowlisted_values =
      Map.merge(runtime_values, %{"PATH" => System.get_env("PATH") || ""})
      |> maybe_add_auth_environment("OPENAI_API_KEY")
      |> maybe_add_auth_environment("CODEX_API_KEY")

    cleared = Enum.map(inherited_names, &{String.to_charlist(&1), false})

    allowed =
      Enum.map(allowlisted_values, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    Enum.uniq_by(allowed ++ cleared, &elem(&1, 0))
  end

  defp maybe_add_auth_environment(environment, key) do
    case System.get_env(key) do
      value when is_binary(value) and value != "" -> Map.put(environment, key, value)
      _ -> environment
    end
  end
end
