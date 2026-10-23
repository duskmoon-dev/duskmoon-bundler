defmodule Mix.Tasks.HoloTest do
  use Hologram.Test.BasicCase, async: false

  import Hologram.Test.Stubs
  import Mox

  use_module_stub :asset_manifest_cache
  use_module_stub :asset_path_registry
  use_module_stub :chunk_registry
  use_module_stub :page_digest_registry
  use_module_stub :page_module_resolver

  setup :set_mox_global

  setup do
    setup_asset_path_registry(AssetPathRegistryStub, false)
    setup_asset_manifest_cache(AssetManifestCacheStub, false)
    setup_chunk_registry(ChunkRegistryStub, false)
    setup_page_digest_registry(PageDigestRegistryStub, false)
    setup_page_module_resolver(PageModuleResolverStub, false)

    original_hologram_start_flag = System.get_env("HOLOGRAM_START")
    System.delete_env("HOLOGRAM_START")

    # The umbrella test task already ran app.start before test_helper stopped this app.
    Mix.Task.reenable("app.start")

    # credo:disable-for-next-line Credo.Check.Design.AliasUsage
    task = Task.async(fn -> Mix.Tasks.Holo.run([]) end)

    Process.sleep(500)

    on_exit(fn ->
      Process.exit(task.pid, :kill)

      # Mix.Tasks.Phx.Server sets System.no_halt(true) which is a global VM flag
      # that persists after process kill. Reset it so the BEAM can exit.
      System.no_halt(false)

      Application.stop(:duskmoon_hologram)

      if original_hologram_start_flag do
        System.put_env("HOLOGRAM_START", original_hologram_start_flag)
      else
        System.delete_env("HOLOGRAM_START")
      end
    end)
  end

  describe "run/1" do
    test "sets HOLOGRAM_START env var to 1" do
      assert System.get_env("HOLOGRAM_START") == "1"
    end

    test "starts the application" do
      started_apps = Enum.map(Application.started_applications(), &elem(&1, 0))

      assert :duskmoon_hologram in started_apps
    end
  end
end
