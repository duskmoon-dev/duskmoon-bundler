defmodule NPM.CacheAtomicTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias NPM.Cache

  @moduletag :tmp_dir

  defmodule Server do
    @moduledoc false
    import Plug.Conn

    def init(options), do: options

    def call(conn, {owner, archive}) do
      send(owner, {:tarball_request, conn.request_path})

      # Lets a test act while the download is in flight.
      case Application.get_env(:duskmoon_npm, :cache_atomic_test_hook) do
        nil -> :ok
        hook -> hook.()
      end

      case conn.request_path do
        "/missing/" <> _ -> send_resp(conn, 404, "missing")
        _ -> conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, archive)
      end
    end
  end

  @env ~w(NPM_REGISTRY NPM_TOKEN NPM_MIRROR NPM_EX_ALLOWED_REGISTRIES NPM_EX_CACHE_DIR)
  @app [:registry, :token, :mirror, :cache_dir, :allowed_registries, :cache_atomic_test_hook]

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

    archive_path = Path.join(tmp_dir, "pkg.tgz")

    :ok =
      :erl_tar.create(
        String.to_charlist(archive_path),
        [{~c"package/package.json", ~s({"name":"pkg","version":"1.0.0","from":"download"})}],
        [:compressed]
      )

    archive = File.read!(archive_path)

    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {Server, {self(), archive}}, ip: {127, 0, 0, 1}, port: 0}
      )

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    registry = "http://127.0.0.1:#{port}"
    Application.put_env(:duskmoon_npm, :registry, registry)

    {:ok,
     registry: registry,
     integrity: "sha512-" <> Base.encode64(:crypto.hash(:sha512, archive)),
     dest: Cache.package_dir("pkg", "1.0.0")}
  end

  defp write_entry!(dest, from, integrity) do
    File.mkdir_p!(dest)

    File.write!(
      Path.join(dest, "package.json"),
      ~s({"name":"pkg","version":"1.0.0","from":"#{from}"})
    )

    File.write!(Path.join(dest, ".npm-ex-cache-complete"), "1\n#{integrity}\n")
  end

  defp from(dest), do: NPM.JSON.decode!(File.read!(Path.join(dest, "package.json")))["from"]

  defp siblings(dest), do: dest |> Path.dirname() |> File.ls!() |> Enum.sort()

  test "installs a downloaded package and leaves no temporary directories", context do
    %{registry: registry, integrity: integrity, dest: dest} = context

    assert {:ok, ^dest} =
             Cache.ensure("pkg", "1.0.0", "#{registry}/pkg/-/pkg-1.0.0.tgz", integrity)

    assert from(dest) == "download"
    assert Cache.cached?("pkg", "1.0.0", integrity)
    assert siblings(dest) == ["1.0.0"]
  end

  test "the destination does not exist until the package is complete", context do
    %{registry: registry, integrity: integrity, dest: dest} = context
    test_pid = self()

    Application.put_env(:duskmoon_npm, :cache_atomic_test_hook, fn ->
      send(test_pid, {:dest_during_download, File.exists?(dest)})
    end)

    assert {:ok, ^dest} =
             Cache.ensure("pkg", "1.0.0", "#{registry}/pkg/-/pkg-1.0.0.tgz", integrity)

    assert_received {:dest_during_download, false}
  end

  test "keeps a complete entry another process finished during the download", context do
    %{registry: registry, integrity: integrity, dest: dest} = context

    Application.put_env(:duskmoon_npm, :cache_atomic_test_hook, fn ->
      write_entry!(dest, "other-process", integrity)
    end)

    assert {:ok, ^dest} =
             Cache.ensure("pkg", "1.0.0", "#{registry}/pkg/-/pkg-1.0.0.tgz", integrity)

    assert_received {:tarball_request, _path}
    assert from(dest) == "other-process"
    assert siblings(dest) == ["1.0.0"]
  end

  test "a failed download does not delete an existing complete entry", context do
    %{registry: registry, integrity: integrity, dest: dest} = context
    write_entry!(dest, "existing", "sha512-b2xk")

    capture_io(:stderr, fn ->
      assert {:error, {:fetch_failed, "pkg", "1.0.0", {:http, 404}}} =
               Cache.ensure("pkg", "1.0.0", "#{registry}/missing/pkg-1.0.0.tgz", integrity)
    end)

    assert from(dest) == "existing"
    assert Cache.cached?("pkg", "1.0.0", "sha512-b2xk")
    refute Cache.cached?("pkg", "1.0.0", integrity)
    assert siblings(dest) == ["1.0.0"]
  end

  test "replaces an entry verified against a different integrity", context do
    %{registry: registry, integrity: integrity, dest: dest} = context
    write_entry!(dest, "existing", "sha512-b2xk")

    assert {:ok, ^dest} =
             Cache.ensure("pkg", "1.0.0", "#{registry}/pkg/-/pkg-1.0.0.tgz", integrity)

    assert from(dest) == "download"
    assert Cache.cached?("pkg", "1.0.0", integrity)
    assert siblings(dest) == ["1.0.0"]
  end

  test "replaces an incomplete entry left by an interrupted extraction", context do
    %{registry: registry, integrity: integrity, dest: dest} = context
    File.mkdir_p!(Path.join(dest, "lib"))
    File.write!(Path.join(dest, "lib/partial.js"), "partial")

    assert {:ok, ^dest} =
             Cache.ensure("pkg", "1.0.0", "#{registry}/pkg/-/pkg-1.0.0.tgz", integrity)

    assert from(dest) == "download"
    refute File.exists?(Path.join(dest, "lib/partial.js"))
    assert siblings(dest) == ["1.0.0"]
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:duskmoon_npm, key)
  defp restore_app_env(key, value), do: Application.put_env(:duskmoon_npm, key, value)
end
