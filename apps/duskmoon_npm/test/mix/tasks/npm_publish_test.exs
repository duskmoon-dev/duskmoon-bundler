defmodule Mix.Tasks.Npm.PublishTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  defmodule Server do
    @moduledoc false
    import Plug.Conn

    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = read_body(conn, length: 1_000_000)
      send(owner, {:publish_request, conn.method, conn.request_path, conn.req_headers, body})

      case conn.request_path do
        "/rejected" -> send_resp(conn, 409, ~s({"error":"conflict"}))
        "/redirect" -> conn |> put_resp_header("location", "/stolen") |> send_resp(307, "")
        _ -> send_resp(conn, 201, "{}")
      end
    end
  end

  @env ~w(NPM_REGISTRY NPM_TOKEN NPM_EX_ALLOWED_REGISTRIES)
  @app [:registry, :token, :allowed_registries]

  setup %{tmp_dir: tmp_dir} do
    old_cwd = File.cwd!()
    old_env = Map.new(@env, &{&1, System.get_env(&1)})
    old_app = Map.new(@app, &{&1, Application.get_env(:duskmoon_npm, &1)})
    Enum.each(@env, &System.delete_env/1)

    server = start_supervised!({Gaoxy.HTTP, plug: {Server, self()}, ip: {127, 0, 0, 1}, port: 0})
    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    registry = "http://127.0.0.1:#{port}"
    Application.put_env(:duskmoon_npm, :registry, registry)
    Application.put_env(:duskmoon_npm, :token, "publish-token")
    Application.delete_env(:duskmoon_npm, :allowed_registries)

    File.cd!(tmp_dir)
    File.write!("package.json", ~s({"name":"publish-fixture","version":"1.2.3","files":["dist"]}))
    File.mkdir_p!("dist")
    File.write!("dist/index.js", "module.exports = 1\n")
    File.write!("secret.txt", "not for publishing")
    File.write!(".npmrc", "//127.0.0.1/:_authToken=project-secret\n")

    on_exit(fn ->
      File.cd!(old_cwd)

      Enum.each(old_env, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      Enum.each(old_app, fn {k, v} ->
        if v,
          do: Application.put_env(:duskmoon_npm, k, v),
          else: Application.delete_env(:duskmoon_npm, k)
      end)
    end)

    {:ok, registry: registry}
  end

  test "uploads version metadata and the matching tarball before reporting success", %{
    registry: registry
  } do
    output = capture_io(fn -> assert :ok = Mix.Tasks.Npm.Publish.run(["--tag", "beta"]) end)
    assert output =~ "Published publish-fixture@1.2.3"
    assert_received {:publish_request, "PUT", "/publish-fixture", headers, body}
    assert {"authorization", "Bearer publish-token"} in headers

    assert %{
             "dist-tags" => %{"beta" => "1.2.3"},
             "versions" => %{"1.2.3" => %{"name" => "publish-fixture", "dist" => dist}},
             "_attachments" => %{"publish-fixture-1.2.3.tgz" => attachment}
           } = JSON.decode!(body)

    tarball = Base.decode64!(attachment["data"])
    assert attachment["length"] == byte_size(tarball)
    assert dist["integrity"] == "sha512-" <> Base.encode64(:crypto.hash(:sha512, tarball))
    assert dist["shasum"] == Base.encode16(:crypto.hash(:sha, tarball), case: :lower)
    assert dist["tarball"] == registry <> "/publish-fixture/-/publish-fixture-1.2.3.tgz"

    assert {:ok, entries} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

    assert Enum.sort(Enum.map(entries, &elem(&1, 0))) == [
             ~c"package/dist/index.js",
             ~c"package/package.json"
           ]

    refute body =~ "project-secret"
    refute File.exists?("publish-fixture-1.2.3.tgz")
  end

  test "--dry-run packs the same file set without contacting the registry" do
    output = capture_io(fn -> Mix.Tasks.Npm.Publish.run(["--dry-run", "--tag", "beta"]) end)

    assert output =~ "Dry run"
    assert output =~ "publish-fixture"
    assert output =~ "dist/index.js"
    assert output =~ "beta"
    refute output =~ "secret.txt"
    refute_received {:publish_request, _, _, _, _}
  end

  test "mix npm.pack uses the same tarball contents as publish dry-run" do
    capture_io(fn -> Mix.Tasks.Npm.Pack.run([]) end)

    assert {:ok, entries} =
             :erl_tar.extract(~c"publish-fixture-1.2.3.tgz", [:compressed, :memory])

    assert Enum.sort(Enum.map(entries, &elem(&1, 0))) == [
             ~c"package/dist/index.js",
             ~c"package/package.json"
           ]
  end

  test "registry failures and redirects raise without reporting success" do
    for {name, status} <- [{"rejected", 409}, {"redirect", 307}] do
      update_package(%{"name" => name})

      {error, output} =
        with_io(fn -> assert_raise Mix.Error, fn -> Mix.Tasks.Npm.Publish.run([]) end end)

      assert Exception.message(error) =~ Integer.to_string(status)
      refute output =~ "Published"
      assert_received {:publish_request, "PUT", path, _, _}
      assert path == "/" <> name
      refute_received {:publish_request, _, "/stolen", _, _}
    end
  end

  test "private packages and invalid versions are rejected before network access" do
    for data <- [%{"private" => true}, %{"private" => false, "version" => "../../secret"}] do
      update_package(data)
      assert_raise Mix.Error, fn -> Mix.Tasks.Npm.Publish.run([]) end
      refute_received {:publish_request, _, _, _, _}
    end
  end

  test "a scoped registry gets its own token and publishConfig tag and access", %{
    registry: registry
  } do
    update_package(%{
      "name" => "@fixture/scoped",
      "publishConfig" => %{"tag" => "next", "access" => "public"}
    })

    File.write!(
      ".npmrc",
      "@fixture:registry=#{registry}/scoped\n//127.0.0.1:#{URI.parse(registry).port}/scoped/:_authToken=scoped-token\n"
    )

    Application.put_env(:duskmoon_npm, :registry, "https://registry.npmjs.org")

    capture_io(fn -> assert :ok = Mix.Tasks.Npm.Publish.run([]) end)
    assert_received {:publish_request, "PUT", "/scoped/@fixture%2fscoped", headers, body}
    assert {"authorization", "Bearer scoped-token"} in headers
    refute {"authorization", "Bearer publish-token"} in headers
    assert %{"dist-tags" => %{"next" => "1.2.3"}, "access" => "public"} = JSON.decode!(body)
  end

  test "a package cannot redirect the global token through publishConfig", %{registry: registry} do
    update_package(%{"publishConfig" => %{"registry" => registry}})
    Application.put_env(:duskmoon_npm, :registry, "https://registry.npmjs.org")
    Application.put_env(:duskmoon_npm, :allowed_registries, [registry])
    File.rm!(".npmrc")

    assert_raise Mix.Error, ~r/no.*token/i, fn -> Mix.Tasks.Npm.Publish.run([]) end
    refute_received {:publish_request, _, _, _, _}
  end

  defp update_package(fields) do
    data = "package.json" |> File.read!() |> JSON.decode!() |> Map.merge(fields)
    File.write!("package.json", JSON.encode!(data))
  end
end
