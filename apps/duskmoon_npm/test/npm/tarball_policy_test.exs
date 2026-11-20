defmodule NPM.TarballPolicyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Npm.Ci

  @moduletag :tmp_dir

  defmodule Server do
    @moduledoc false
    import Plug.Conn

    def init(options), do: options

    def call(conn, {owner, tag, tarball}) do
      send(owner, {:tarball_request, tag, conn.request_path, conn.req_headers})
      conn = fetch_query_params(conn)

      case conn.request_path do
        "/redirect" ->
          conn |> put_resp_header("location", conn.query_params["to"]) |> send_resp(302, "")

        "/loop" ->
          conn |> put_resp_header("location", "/loop") |> send_resp(302, "")

        _ ->
          conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, tarball)
      end
    end
  end

  @env ~w(NPM_REGISTRY NPM_TOKEN NPM_MIRROR NPM_EX_ALLOWED_REGISTRIES
          NPM_EX_ALLOW_REGISTRY_REDIRECTS NPM_EX_MAX_TARBALL_BYTES NPM_EX_MAX_UNPACKED_BYTES)
  @app [
    :registry,
    :token,
    :mirror,
    :cache_dir,
    :allowed_registries,
    :allow_registry_redirects,
    :max_tarball_bytes,
    :max_unpacked_bytes
  ]

  setup %{tmp_dir: tmp_dir} do
    old_cwd = File.cwd!()
    old_env = Map.new(@env, &{&1, System.get_env(&1)})
    old_app = Map.new(@app, &{&1, Application.get_env(:duskmoon_npm, &1)})

    Enum.each(@env, &System.delete_env/1)
    Enum.each(@app, &Application.delete_env(:duskmoon_npm, &1))
    File.cd!(tmp_dir)
    Application.put_env(:duskmoon_npm, :cache_dir, Path.join(tmp_dir, "cache-root"))

    on_exit(fn ->
      File.cd!(old_cwd)
      Enum.each(old_env, fn {k, v} -> restore_env(k, v) end)
      Enum.each(old_app, fn {k, v} -> restore_app_env(k, v) end)
    end)

    archive = tgz!(tmp_dir, [{~c"package/package.json", ~s({"name":"pkg","version":"1.0.0"})}])
    integrity = "sha512-" <> Base.encode64(:crypto.hash(:sha512, archive))
    registry = start_server!(:registry, archive)
    other = start_server!(:other, archive)

    Application.put_env(:duskmoon_npm, :registry, registry)
    Application.put_env(:duskmoon_npm, :token, "registry-token")

    {:ok,
     registry: registry,
     other: other,
     archive: archive,
     integrity: integrity,
     dest: Path.join(tmp_dir, "extracted")}
  end

  defp start_server!(tag, archive) do
    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {Server, {self(), tag, archive}}, ip: {127, 0, 0, 1}, port: 0},
        id: tag
      )

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    "http://127.0.0.1:#{port}"
  end

  defp tgz!(dir, entries) do
    path = Path.join(dir, "fixture-#{System.unique_integer([:positive])}.tgz")
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.read!(path)
  end

  defp authorization(headers), do: List.keyfind(headers, "authorization", 0)

  describe "authorization" do
    test "is sent when the tarball is on the registry origin", context do
      %{registry: registry, integrity: integrity, dest: dest} = context

      assert {:ok, 1} =
               NPM.Tarball.fetch_and_extract("#{registry}/pkg/-/pkg-1.0.0.tgz", integrity, dest)

      assert_received {:tarball_request, :registry, "/pkg/-/pkg-1.0.0.tgz", headers}
      assert authorization(headers) == {"authorization", "Bearer registry-token"}
    end

    test "is never sent to a tarball on another origin", context do
      %{other: other, integrity: integrity, dest: dest} = context

      assert {:ok, 1} =
               NPM.Tarball.fetch_and_extract("#{other}/pkg/-/pkg-1.0.0.tgz", integrity, dest)

      assert_received {:tarball_request, :other, _path, headers}
      refute authorization(headers)
    end

    test "uses the token of the registry the package was resolved from", context do
      %{registry: registry, other: other, integrity: integrity, dest: dest} = context
      "http://" <> other_host = other
      File.write!(".npmrc", "//#{other_host}/:_authToken=scope-token\n")

      assert {:ok, 1} =
               NPM.Tarball.fetch_and_extract("#{other}/pkg/-/pkg-1.0.0.tgz", integrity, dest,
                 registry: other
               )

      assert_received {:tarball_request, :other, _path, headers}
      assert authorization(headers) == {"authorization", "Bearer scope-token"}

      # The scope registry's token never goes to the default registry.
      assert {:ok, 1} =
               NPM.Tarball.fetch_and_extract("#{registry}/pkg/-/pkg-1.0.0.tgz", integrity, dest,
                 registry: other
               )

      assert_received {:tarball_request, :registry, _path, headers}
      refute authorization(headers)
    end

    test "Cache.ensure authenticates scoped tarballs against the scope registry", context do
      %{other: other, integrity: integrity} = context
      "http://" <> other_host = other

      File.write!(".npmrc", """
      @corp:registry=#{other}/
      //#{other_host}/:_authToken=scope-token
      """)

      assert {:ok, _path} =
               NPM.Cache.ensure(
                 "@corp/ui",
                 "1.0.0",
                 "#{other}/@corp/ui/-/ui-1.0.0.tgz",
                 integrity
               )

      assert_received {:tarball_request, :other, "/@corp/ui/-/ui-1.0.0.tgz", headers}
      assert authorization(headers) == {"authorization", "Bearer scope-token"}
      # The private package is never requested from the default registry.
      refute_received {:tarball_request, :registry, _path, _headers}
    end
  end

  describe "redirects" do
    test "same-origin redirects are followed and keep authorization", context do
      %{registry: registry, integrity: integrity, dest: dest} = context

      assert {:ok, 1} =
               NPM.Tarball.fetch_and_extract(
                 "#{registry}/redirect?to=/pkg.tgz",
                 integrity,
                 dest
               )

      assert_received {:tarball_request, :registry, "/redirect", _headers}
      assert_received {:tarball_request, :registry, "/pkg.tgz", headers}
      assert authorization(headers) == {"authorization", "Bearer registry-token"}
    end

    test "cross-origin redirects are blocked by default", context do
      %{registry: registry, other: other, integrity: integrity, dest: dest} = context
      target = "#{other}/pkg.tgz"

      assert {:error, {:redirect_blocked, ^target}} =
               NPM.Tarball.fetch_and_extract(
                 "#{registry}/redirect?to=#{URI.encode_www_form(target)}",
                 integrity,
                 dest
               )

      refute_received {:tarball_request, :other, _path, _headers}
    end

    test "allowed cross-origin redirects never forward authorization", context do
      %{registry: registry, other: other, integrity: integrity, dest: dest} = context
      Application.put_env(:duskmoon_npm, :allow_registry_redirects, true)

      assert {:ok, 1} =
               NPM.Tarball.fetch_and_extract(
                 "#{registry}/redirect?to=#{URI.encode_www_form("#{other}/pkg.tgz")}",
                 integrity,
                 dest
               )

      assert_received {:tarball_request, :registry, "/redirect", headers}
      assert authorization(headers) == {"authorization", "Bearer registry-token"}
      assert_received {:tarball_request, :other, "/pkg.tgz", headers}
      refute authorization(headers)
    end

    test "redirects to another allowed registry origin are followed without authorization",
         context do
      %{registry: registry, other: other, integrity: integrity, dest: dest} = context
      Application.put_env(:duskmoon_npm, :allowed_registries, [registry, other])

      assert {:ok, 1} =
               NPM.Tarball.fetch_and_extract(
                 "#{registry}/redirect?to=#{URI.encode_www_form("#{other}/pkg.tgz")}",
                 integrity,
                 dest
               )

      assert_received {:tarball_request, :other, "/pkg.tgz", headers}
      refute authorization(headers)
    end

    test "redirect loops stop with an error", context do
      %{registry: registry, integrity: integrity, dest: dest} = context

      assert {:error, :too_many_redirects} =
               NPM.Tarball.fetch_and_extract("#{registry}/loop", integrity, dest)
    end
  end

  describe "size limits" do
    test "rejects a download larger than the configured maximum", context do
      %{registry: registry, archive: archive, integrity: integrity, dest: dest} = context
      limit = byte_size(archive) - 1
      Application.put_env(:duskmoon_npm, :max_tarball_bytes, limit)

      assert {:error, {:tarball_too_large, ^limit}} =
               NPM.Tarball.fetch_and_extract("#{registry}/pkg.tgz", integrity, dest)

      refute File.exists?(Path.join(dest, "package.json"))

      System.put_env("NPM_EX_MAX_TARBALL_BYTES", "#{byte_size(archive)}")
      assert {:ok, 1} = NPM.Tarball.fetch_and_extract("#{registry}/pkg.tgz", integrity, dest)
    end

    test "rejects an archive that unpacks beyond the configured maximum", %{tmp_dir: dir} do
      # Highly compressible: tiny download, large unpacked size.
      bomb = tgz!(dir, [{~c"package/zeros.bin", :binary.copy(<<0>>, 2_000_000)}])
      assert byte_size(bomb) < 50_000
      dest = Path.join(dir, "bomb")

      Application.put_env(:duskmoon_npm, :max_unpacked_bytes, 1_000_000)
      assert {:error, {:unpacked_too_large, 1_000_000}} = NPM.Tarball.extract(bomb, dest)
      refute File.exists?(Path.join(dest, "zeros.bin"))

      System.put_env("NPM_EX_MAX_UNPACKED_BYTES", "4000000")
      assert {:ok, 1} = NPM.Tarball.extract(bomb, dest)
      assert File.stat!(Path.join(dest, "zeros.bin")).size == 2_000_000
    end

    test "Cache.ensure rejects a declared unpackedSize over the limit before downloading",
         context do
      %{registry: registry, integrity: integrity} = context
      Application.put_env(:duskmoon_npm, :max_unpacked_bytes, 1_000)

      assert {:error, {:unpacked_too_large, "pkg", "1.0.0", 1_001}} =
               NPM.Cache.ensure("pkg", "1.0.0", "#{registry}/pkg/-/pkg-1.0.0.tgz", integrity,
                 unpacked_size: 1_001
               )

      refute_received {:tarball_request, _tag, _path, _headers}
      refute NPM.Cache.cached?("pkg", "1.0.0")
    end

    test "defaults are generous" do
      assert NPM.Config.max_tarball_bytes() >= 256 * 1024 * 1024
      assert NPM.Config.max_unpacked_bytes() >= NPM.Config.max_tarball_bytes()
    end
  end

  describe "missing integrity" do
    setup context do
      File.write!(
        "package.json",
        NPM.JSON.encode_pretty(%{"name" => "app", "dependencies" => %{"pkg" => "1.0.0"}})
      )

      entry = %{
        version: "1.0.0",
        integrity: "",
        tarball: "#{context.registry}/pkg/-/pkg-1.0.0.tgz",
        dependencies: %{},
        optional_dependencies: %{},
        has_install_script: false
      }

      {:ok, entry: entry}
    end

    test "a frozen install rejects a lock entry without integrity", %{entry: entry} do
      assert :ok = NPM.Lockfile.write(%{"pkg" => entry})

      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert {:error, {:missing_integrity, "pkg", "1.0.0"}} = NPM.install(frozen: true)
        end)
      end)

      refute_received {:tarball_request, _tag, _path, _headers}
      refute File.exists?("node_modules/pkg")
    end

    test "a frozen install rejects it on a cache hit too", %{entry: entry} do
      assert :ok = NPM.Lockfile.write(%{"pkg" => entry})

      capture_io(:stderr, fn ->
        capture_io(fn -> assert :ok = NPM.install() end)
      end)

      assert NPM.Cache.cached?("pkg", "1.0.0")
      File.rm_rf!("node_modules")

      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert {:error, {:missing_integrity, "pkg", "1.0.0"}} = NPM.install(frozen: true)
        end)
      end)

      refute File.exists?("node_modules/pkg")
    end

    test "a frozen install rejects nested lock entries without integrity", context do
      %{entry: entry, integrity: integrity} = context
      flat = %{"pkg" => %{entry | integrity: integrity}}
      nested = %{"node_modules/pkg/node_modules/inner" => entry}
      assert :ok = NPM.Lockfile.write(flat, nested: nested)

      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert {:error, {:missing_integrity, "inner", "1.0.0"}} = NPM.install(frozen: true)
        end)
      end)
    end

    test "mix npm.ci fails on a lock entry without integrity", %{entry: entry} do
      assert :ok = NPM.Lockfile.write(%{"pkg" => entry})
      Mix.Task.reenable("npm.ci")

      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert_raise Mix.Error, ~r/missing_integrity/, fn -> Ci.run([]) end
        end)
      end)
    end

    test "an ordinary install still only warns", %{entry: entry} do
      assert :ok = NPM.Lockfile.write(%{"pkg" => entry})

      warning =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert :ok = NPM.install() end)
        end)

      assert warning =~ "no integrity recorded"
      assert File.exists?("node_modules/pkg/package.json")
    end

    test "a frozen install with integrity succeeds", %{entry: entry, integrity: integrity} do
      assert :ok = NPM.Lockfile.write(%{"pkg" => %{entry | integrity: integrity}})

      capture_io(fn -> assert :ok = NPM.install(frozen: true) end)
      assert File.exists?("node_modules/pkg/package.json")
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:duskmoon_npm, key)
  defp restore_app_env(key, value), do: Application.put_env(:duskmoon_npm, key, value)
end
