defmodule NPM.ScopedRegistryTest do
  use ExUnit.Case, async: false

  alias NPM.Security.RegistryPolicy

  @moduletag :tmp_dir

  defmodule Server do
    @moduledoc false
    import Plug.Conn

    def init(options), do: options

    def call(conn, {owner, tag}) do
      send(owner, {:registry_request, tag, conn.request_path, conn.req_headers})

      body =
        JSON.encode!(%{
          "name" => "served-by-#{tag}",
          "versions" => %{
            "1.0.0" => %{
              "dist" => %{
                "tarball" => "https://elsewhere.example/pkg/-/pkg-1.0.0.tgz",
                "integrity" => "sha512-hash"
              }
            }
          }
        })

      conn
      |> put_resp_content_type("application/vnd.npm.install-v1+json")
      |> send_resp(200, body)
    end
  end

  @env ~w(NPM_REGISTRY NPM_TOKEN NPM_MIRROR NPM_EX_CACHE_DIR NPM_EX_ALLOWED_REGISTRIES
          NPM_EX_ALLOW_REGISTRY_REDIRECTS HOME)
  @app [:registry, :token, :mirror, :cache_dir, :allowed_registries, :allow_registry_redirects]

  setup %{tmp_dir: tmp_dir} do
    old_cwd = File.cwd!()
    old_env = Map.new(@env, &{&1, System.get_env(&1)})
    old_app = Map.new(@app, &{&1, Application.get_env(:duskmoon_npm, &1)})

    Enum.each(@env, &System.delete_env/1)
    Enum.each(@app, &Application.delete_env(:duskmoon_npm, &1))

    project = Path.join(tmp_dir, "project")
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(project)
    File.mkdir_p!(home)
    File.cd!(project)
    System.put_env("HOME", home)
    Application.put_env(:duskmoon_npm, :cache_dir, Path.join(tmp_dir, "cache-root"))

    on_exit(fn ->
      File.cd!(old_cwd)
      Enum.each(old_env, fn {k, v} -> restore_env(k, v) end)
      Enum.each(old_app, fn {k, v} -> restore_app_env(k, v) end)
    end)

    default = start_registry!(:default)
    corp = start_registry!(:corp)
    Application.put_env(:duskmoon_npm, :registry, default)
    Application.put_env(:duskmoon_npm, :token, "default-token")

    {:ok, default: default, corp: corp}
  end

  defp start_registry!(tag) do
    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {Server, {self(), tag}}, ip: {127, 0, 0, 1}, port: 0},
        id: tag
      )

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    "http://127.0.0.1:#{port}"
  end

  defp host(url), do: String.replace_prefix(url, "http://", "")

  describe "NPM.Config.registry_for/1" do
    test "selects the .npmrc scope registry only for that scope", %{default: default} do
      File.write!(".npmrc", "@corp:registry=https://npm.corp.example/npm/\n")

      assert NPM.Config.registry_for("@corp/ui") == "https://npm.corp.example/npm"
      assert NPM.Config.registry_for("@corporate/ui") == default
      assert NPM.Config.registry_for("@other/ui") == default
      assert NPM.Config.registry_for("corp") == default
      assert NPM.Config.registry_for("lodash") == default
    end

    test "scope registries join the default allowed origins", %{default: default} do
      File.write!(".npmrc", "@corp:registry=https://npm.corp.example/npm/\n")

      assert Enum.sort(RegistryPolicy.allowed_origins()) ==
               Enum.sort([default, "https://npm.corp.example"])
    end
  end

  describe "NPM.Registry.get_packument/1" do
    test "fetches a scoped package from its scope registry with that registry's token", %{
      corp: corp
    } do
      File.write!(".npmrc", """
      @corp:registry=#{corp}/
      //#{host(corp)}/:_authToken=corp-token
      """)

      assert {:ok, %{name: "served-by-corp"}} = NPM.Registry.get_packument("@corp/ui")

      assert_received {:registry_request, :corp, "/@corp%2fui", headers}
      assert {"authorization", "Bearer corp-token"} in headers
      refute_received {:registry_request, :default, _path, _headers}
    end

    test "never sends the global token to a scope registry", %{corp: corp} do
      File.write!(".npmrc", "@corp:registry=#{corp}/\n")

      assert {:ok, _} = NPM.Registry.get_packument("@corp/ui")

      assert_received {:registry_request, :corp, _path, headers}
      refute List.keymember?(headers, "authorization", 0)
    end

    test "keeps other packages on the default registry and never sends the scope token there",
         %{corp: corp} do
      File.write!(".npmrc", """
      @corp:registry=#{corp}/
      //#{host(corp)}/:_authToken=corp-token
      """)

      assert {:ok, %{name: "served-by-default"}} = NPM.Registry.get_packument("lodash")
      assert {:ok, %{name: "served-by-default"}} = NPM.Registry.get_packument("@other/ui")

      assert_received {:registry_request, :default, "/lodash", headers}
      assert {"authorization", "Bearer default-token"} in headers
      assert_received {:registry_request, :default, "/@other%2fui", headers}
      assert {"authorization", "Bearer default-token"} in headers
      refute_received {:registry_request, :corp, _path, _headers}
    end

    test "rewrites untrusted tarball origins to the scope registry", %{corp: corp} do
      File.write!(".npmrc", "@corp:registry=#{corp}/\n")

      assert {:ok, packument} = NPM.Registry.get_packument("@corp/ui")
      tarball = packument.versions["1.0.0"].dist.tarball
      assert String.starts_with?(tarball, corp <> "/")

      # Cache hits are normalised the same way.
      assert {:ok, cached} = NPM.Registry.get_packument("@corp/ui")
      assert cached.versions["1.0.0"].dist.tarball == tarball
      refute_received {:registry_request, :default, _path, _headers}
    end

    test "fails loudly instead of falling back when the scope registry is not allowed", %{
      default: default,
      corp: corp
    } do
      File.write!(".npmrc", "@corp:registry=#{corp}/\n")
      Application.put_env(:duskmoon_npm, :allowed_registries, [default])

      assert_raise RegistryPolicy.Error, fn -> NPM.Registry.get_packument("@corp/ui") end

      refute_received {:registry_request, _tag, _path, _headers}
    end

    test "does not share cached packuments between the default and scope registries", %{
      corp: corp
    } do
      assert {:ok, %{name: "served-by-default"}} = NPM.Registry.get_packument("@corp/ui")

      File.write!(".npmrc", "@corp:registry=#{corp}/\n")
      assert {:ok, %{name: "served-by-corp"}} = NPM.Registry.get_packument("@corp/ui")
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:duskmoon_npm, key)
  defp restore_app_env(key, value), do: Application.put_env(:duskmoon_npm, key, value)
end
