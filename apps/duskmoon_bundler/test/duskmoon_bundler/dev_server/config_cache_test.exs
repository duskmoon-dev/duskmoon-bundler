defmodule DuskmoonBundler.DevServer.ConfigCacheTest do
  use ExUnit.Case, async: true
  alias DuskmoonBundler.DevServer.ConfigCache
  alias DuskmoonBundler.JS.TSConfig
  @moduletag :tmp_dir

  test "reuses resolved config but detects equal-size edits with unchanged timestamps", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "tsconfig.json")
    File.write!(path, ~s({"compilerOptions":{"paths":{"@/*":["./one/*"]}}}))
    stat = File.stat!(path)

    resolve = fn ->
      send(self(), :resolved)
      TSConfig.read_paths(path)
    end

    assert %{"@" => first} = ConfigCache.fetch([], resolve, dir)
    assert first == Path.join(dir, "one")
    assert_received :resolved
    assert %{"@" => ^first} = ConfigCache.fetch([], resolve, dir)
    refute_received :resolved

    File.write!(path, ~s({"compilerOptions":{"paths":{"@/*":["./two/*"]}}}))
    File.touch!(path, stat.mtime)
    assert %{"@" => second} = ConfigCache.fetch([], resolve, dir)
    assert second == Path.join(dir, "two")
    assert_received :resolved
  end

  test "invalidates on dotenv creation and deletion and separates profile options", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, ".env.development.local")
    resolve = fn -> File.read(path) end
    assert {:error, :enoent} = ConfigCache.fetch([profile: :first], resolve, dir)
    File.write!(path, "DUSKMOON_BUNDLER_NAME=created")

    assert {:ok, "DUSKMOON_BUNDLER_NAME=created"} =
             ConfigCache.fetch([profile: :first], resolve, dir)

    assert :second = ConfigCache.fetch([profile: :second], fn -> :second end, dir)
    File.rm!(path)
    assert {:error, :enoent} = ConfigCache.fetch([profile: :first], resolve, dir)
  end
end
