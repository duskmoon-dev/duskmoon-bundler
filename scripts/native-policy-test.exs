for {app, _namespace} <- [
      {"oxc", OXC},
      {"oxide", Oxide},
      {"vize", Vize},
      {"quickbeam", QuickBEAM}
    ] do
  Code.require_file("../apps/duskmoon_#{app}/lib/#{app}/native_policy.ex", __DIR__)
end

ExUnit.start()

defmodule NativePolicyTest do
  use ExUnit.Case, async: false

  @policies [
    {OXC.NativePolicy, :duskmoon_oxc, "OXC_EX_BUILD", :rustler_precompiled},
    {Oxide.NativePolicy, :duskmoon_oxide, "OXIDE_EX_BUILD", :rustler_precompiled},
    {Vize.NativePolicy, :duskmoon_vize, "VIZE_EX_BUILD", :rustler_precompiled},
    {QuickBEAM.NativePolicy, :duskmoon_quickbeam, "QUICKBEAM_BUILD", :zigler_precompiled}
  ]
  @flags ~w(DUSKMOON_NATIVE_MODE DUSKMOON_BUILD_NATIVE_FROM_SOURCE OXC_EX_BUILD OXIDE_EX_BUILD VIZE_EX_BUILD QUICKBEAM_BUILD RUSTLER_PRECOMPILED_FORCE_BUILD_ALL ZIGLER_PRECOMPILED_FORCE_BUILD_ALL)

  setup do
    saved = for flag <- @flags, do: {flag, System.get_env(flag)}

    config =
      for backend <- [:rustler_precompiled, :zigler_precompiled],
          key <- [:force_build, :force_build_all],
          do: {backend, key, Application.fetch_env(backend, key)}

    Enum.each(@flags, &System.delete_env/1)
    for {backend, key, _} <- config, do: Application.delete_env(backend, key)

    on_exit(fn ->
      for {flag, value} <- saved,
          do: if(value, do: System.put_env(flag, value), else: System.delete_env(flag))

      for {backend, key, value} <- config do
        case value do
          {:ok, v} -> Application.put_env(backend, key, v)
          :error -> Application.delete_env(backend, key)
        end
      end
    end)
  end

  test "default and strict lanes select published artifacts; explicit source selects candidate native sources" do
    for {policy, app, flag, backend} <- @policies do
      refute policy.force_build!(app, flag, "9.16.17", backend)
      System.put_env("DUSKMOON_NATIVE_MODE", "source")
      assert policy.force_build!(app, flag, "9.16.17", backend)
      System.put_env("DUSKMOON_NATIVE_MODE", "precompiled")
      refute policy.force_build!(app, flag, "9.16.17", backend)
      System.delete_env("DUSKMOON_NATIVE_MODE")
    end
  end

  test "legacy flags remain source selectors and conflict with strict mode" do
    for {policy, app, flag, backend} <- @policies do
      for source_flag <- [
            flag,
            "DUSKMOON_BUILD_NATIVE_FROM_SOURCE",
            "RUSTLER_PRECOMPILED_FORCE_BUILD_ALL",
            "ZIGLER_PRECOMPILED_FORCE_BUILD_ALL"
          ] do
        System.put_env(source_flag, "true")
        assert policy.force_build!(app, flag, "9.16.17", backend)
        System.put_env("DUSKMOON_NATIVE_MODE", "precompiled")

        assert_raise RuntimeError, ~r/precompiled conflicts/, fn ->
          policy.force_build!(app, flag, "9.16.17", backend)
        end

        System.delete_env(source_flag)
        System.delete_env("DUSKMOON_NATIVE_MODE")
      end
    end
  end

  test "force-build configuration and prerelease automatic source selection cannot enter strict lane" do
    System.put_env("DUSKMOON_NATIVE_MODE", "precompiled")

    for {policy, app, flag, backend} <- @policies do
      for {key, value} <- [force_build_all: true, force_build: [{app, true}]] do
        Application.put_env(backend, key, value)

        assert_raise RuntimeError, ~r/force_build configuration/, fn ->
          policy.force_build!(app, flag, "9.16.17", backend)
        end

        Application.delete_env(backend, key)
      end

      assert_raise RuntimeError, ~r/rejects -dev/, fn ->
        policy.force_build!(app, flag, "9.16.17-dev", backend)
      end
    end
  end

  test "misspelled policy fails rather than downloading or compiling" do
    System.put_env("DUSKMOON_NATIVE_MODE", "sources")

    assert_raise RuntimeError, ~r/Invalid DUSKMOON_NATIVE_MODE/, fn ->
      OXC.NativePolicy.force_build!(
        :duskmoon_oxc,
        "OXC_EX_BUILD",
        "9.16.17",
        :rustler_precompiled
      )
    end
  end
end
