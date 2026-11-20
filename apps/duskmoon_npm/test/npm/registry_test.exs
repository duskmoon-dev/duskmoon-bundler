defmodule NPM.RegistryTest do
  use ExUnit.Case, async: false

  alias NPM.Security.Age

  defmodule Server do
    @moduledoc false
    import Plug.Conn

    def init(options), do: options

    def call(conn, {owner, attempts}) do
      attempt = Agent.get_and_update(attempts, fn count -> {count, count + 1} end)
      send(owner, {:registry_request, conn.request_path, conn.req_headers})

      case conn.request_path do
        "/retry" when attempt == 0 ->
          send_resp(conn, 503, "unavailable")

        _ ->
          metadata = %{"name" => "example", "versions" => %{"1.0.0" => %{}}}

          metadata =
            if get_req_header(conn, "accept") == ["application/json"] and
                 conn.request_path != "/without-time" do
              timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
              Map.put(metadata, "time", %{"created" => timestamp, "1.0.0" => timestamp})
            else
              metadata
            end

          body = JSON.encode!(metadata)

          conn
          |> put_resp_content_type("application/vnd.npm.install-v1+json")
          |> put_resp_header("content-encoding", "gzip")
          |> send_resp(200, :zlib.gzip(body))
      end
    end
  end

  setup do
    old_registry = Application.get_env(:duskmoon_npm, :registry)
    old_allowed = Application.get_env(:duskmoon_npm, :allowed_registries)
    old_env_allowed = System.get_env("NPM_EX_ALLOWED_REGISTRIES")

    System.delete_env("NPM_EX_ALLOWED_REGISTRIES")

    on_exit(fn ->
      restore_app_env(:registry, old_registry)
      restore_app_env(:allowed_registries, old_allowed)
      restore_env("NPM_EX_ALLOWED_REGISTRIES", old_env_allowed)
    end)

    :ok
  end

  @tag :tmp_dir
  test "fetches compressed registry metadata and retries service failures", %{tmp_dir: dir} do
    configure_http_registry(dir)

    assert {:ok, %{name: "example", versions: %{"1.0.0" => _}}} =
             NPM.Registry.get_packument("retry")

    assert_received {:registry_request, "/retry", headers}
    assert {"accept", "application/json"} in headers
    assert {"authorization", "Bearer registry-test-token"} in headers
    assert_received {:registry_request, "/retry", _headers}

    assert {:ok, %{name: "example"}} = NPM.Registry.get_packument("retry")
    refute_received {:registry_request, _, _headers}
  end

  @tag :tmp_dir
  test "full metadata supplies package and version timestamps for age warnings", %{tmp_dir: dir} do
    configure_http_registry(dir)

    assert {:ok, %{versions: %{"1.0.0" => info}}} = NPM.Registry.get_packument("recent")
    assert [%{type: :new_package}, %{type: :new_version}] = Age.warnings(info)
    assert_received {:registry_request, "/recent", headers}
    assert {"accept", "application/json"} in headers

    assert {:ok, %{versions: %{"1.0.0" => ^info}}} = NPM.Registry.get_packument("recent")
    refute_received {:registry_request, _, _}
  end

  @tag :tmp_dir
  test "disabled age warnings request abbreviated metadata", %{tmp_dir: dir} do
    configure_http_registry(dir)

    for key <- [:package_age_warning_days, :version_age_warning_days] do
      previous = Application.get_env(:duskmoon_npm, key)
      Application.put_env(:duskmoon_npm, key, 0)
      on_exit(fn -> restore_app_env(key, previous) end)
    end

    assert {:ok, %{versions: %{"1.0.0" => info}}} = NPM.Registry.get_packument("abbreviated")
    assert info.created_at == nil
    assert info.published_at == nil
    assert_received {:registry_request, "/abbreviated", headers}
    assert {"accept", "application/vnd.npm.install-v1+json"} in headers
  end

  @tag :tmp_dir
  test "enabling age warnings upgrades an abbreviated cache before its TTL expires", %{
    tmp_dir: dir
  } do
    configure_http_registry(dir)
    Application.put_env(:duskmoon_npm, :package_age_warning_days, 0)
    Application.put_env(:duskmoon_npm, :version_age_warning_days, 0)

    assert {:ok, %{versions: %{"1.0.0" => %{created_at: nil, published_at: nil}}}} =
             NPM.Registry.get_packument("changing-age-policy")

    assert_received {:registry_request, "/changing-age-policy", abbreviated_headers}
    assert {"accept", "application/vnd.npm.install-v1+json"} in abbreviated_headers

    Application.put_env(:duskmoon_npm, :package_age_warning_days, 7)
    Application.put_env(:duskmoon_npm, :version_age_warning_days, 3)

    assert {:ok, %{versions: %{"1.0.0" => full_info}}} =
             NPM.Registry.get_packument("changing-age-policy")

    assert [%{type: :new_package}, %{type: :new_version}] = Age.warnings(full_info)
    assert_received {:registry_request, "/changing-age-policy", full_headers}
    assert {"accept", "application/json"} in full_headers

    assert {:ok, %{versions: %{"1.0.0" => ^full_info}}} =
             NPM.Registry.get_packument("changing-age-policy")

    Application.put_env(:duskmoon_npm, :package_age_warning_days, 0)
    Application.put_env(:duskmoon_npm, :version_age_warning_days, 0)

    assert {:ok, %{versions: %{"1.0.0" => ^full_info}}} =
             NPM.Registry.get_packument("changing-age-policy")

    refute_received {:registry_request, _, _}
  end

  @tag :tmp_dir
  test "registries without timestamps retain their successful full response in cache", %{
    tmp_dir: dir
  } do
    configure_http_registry(dir)

    assert {:ok, %{versions: %{"1.0.0" => %{created_at: nil, published_at: nil}}}} =
             NPM.Registry.get_packument("without-time")

    assert_received {:registry_request, "/without-time", headers}
    assert {"accept", "application/json"} in headers
    assert {:ok, _packument} = NPM.Registry.get_packument("without-time")
    assert {:ok, _packument} = NPM.Registry.get_packument("without-time")
    refute_received {:registry_request, _, _}
  end

  test "rewrites integrity-protected tarballs to the configured registry origin" do
    Application.put_env(:duskmoon_npm, :registry, "https://npm.gsmlg.dev")
    Application.put_env(:duskmoon_npm, :allowed_registries, ["https://npm.gsmlg.dev"])

    assert NPM.Registry.__normalized_tarball_url__(
             "@scope/pkg",
             "1.2.3",
             "https://registry.npmjs.org/@scope/pkg/-/pkg-1.2.3.tgz",
             "sha512-hash"
           ) == "https://npm.gsmlg.dev/@scope%2fpkg/-/pkg-1.2.3.tgz"
  end

  test "keeps no-integrity cross-origin tarballs for later fetch-time validation" do
    Application.put_env(:duskmoon_npm, :registry, "https://npm.gsmlg.dev")
    Application.put_env(:duskmoon_npm, :allowed_registries, ["https://npm.gsmlg.dev"])

    assert NPM.Registry.__normalized_tarball_url__(
             "pkg",
             "1.2.3",
             "https://registry.npmjs.org/pkg/-/pkg-1.2.3.tgz",
             ""
           ) == "https://registry.npmjs.org/pkg/-/pkg-1.2.3.tgz"
  end

  @tag :tmp_dir
  test "reads the registry allowlist once per packument instead of once per version", %{
    tmp_dir: dir
  } do
    old_cache_dir = Application.get_env(:duskmoon_npm, :cache_dir)
    on_exit(fn -> restore_app_env(:cache_dir, old_cache_dir) end)
    Application.put_env(:duskmoon_npm, :cache_dir, dir)
    Application.put_env(:duskmoon_npm, :registry, "https://npm.gsmlg.dev")
    Application.put_env(:duskmoon_npm, :allowed_registries, ["https://npm.gsmlg.dev"])

    versions =
      Map.new(1..40, fn n ->
        tarball = "https://registry.npmjs.org/many/-/many-#{n}.0.0.tgz"
        {"#{n}.0.0", %{dist: %{tarball: tarball, integrity: "sha512-hash"}}}
      end)

    NPM.PackumentCache.put("many", %{name: "many", versions: versions, dist_tags: %{}})

    Code.ensure_loaded!(NPM.Config)
    assert 1 = :erlang.trace_pattern({NPM.Config, :allowed_registries, 0}, true, [:local])
    # A process cannot receive its own call traces, so trace a worker.
    task =
      Task.async(fn ->
        receive do
          :go -> NPM.Registry.get_packument("many")
        end
      end)

    :erlang.trace(task.pid, true, [:call])
    send(task.pid, :go)
    assert {:ok, packument} = Task.await(task)
    :erlang.trace_pattern({NPM.Config, :allowed_registries, 0}, false, [:local])

    assert packument.versions["7.0.0"].dist.tarball ==
             "https://npm.gsmlg.dev/many/-/many-7.0.0.tgz"

    assert count_trace_calls(0) == 1
  end

  defp count_trace_calls(count) do
    receive do
      {:trace, _pid, :call, {NPM.Config, :allowed_registries, []}} -> count_trace_calls(count + 1)
    after
      0 -> count
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:duskmoon_npm, key)
  defp restore_app_env(key, value), do: Application.put_env(:duskmoon_npm, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp configure_http_registry(dir) do
    for key <- [
          "NPM_REGISTRY",
          "NPM_TOKEN",
          "NPM_EX_CACHE_DIR",
          "NPM_EX_ALLOW_REGISTRY_REDIRECTS",
          "NPM_EX_PACKAGE_AGE_WARNING_DAYS",
          "NPM_EX_VERSION_AGE_WARNING_DAYS"
        ] do
      value = System.get_env(key)
      System.delete_env(key)
      on_exit(fn -> restore_env(key, value) end)
    end

    for {key, value} <- [
          cache_dir: dir,
          token: "registry-test-token",
          allow_registry_redirects: false,
          package_age_warning_days: 7,
          version_age_warning_days: 3
        ] do
      old_value = Application.get_env(:duskmoon_npm, key)
      Application.put_env(:duskmoon_npm, key, value)
      on_exit(fn -> restore_app_env(key, old_value) end)
    end

    attempts = start_supervised!({Agent, fn -> 0 end})

    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {Server, {self(), attempts}}, ip: {127, 0, 0, 1}, port: 0}
      )

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    registry = "http://127.0.0.1:#{port}"
    Application.put_env(:duskmoon_npm, :registry, registry)
    Application.put_env(:duskmoon_npm, :allowed_registries, [registry])
  end
end
