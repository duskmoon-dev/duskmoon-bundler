defmodule DuskmoonBundler.CacheTest do
  use ExUnit.Case, async: false

  setup do
    DuskmoonBundler.Cache.clear()
    :ok
  end

  test "get returns nil on miss" do
    assert DuskmoonBundler.Cache.get("/app.ts", 12_345) == nil
  end

  test "put and get round-trip" do
    entry = %{
      code: "const x = 1",
      sourcemap: nil,
      css: nil,
      content_type: "application/javascript"
    }

    DuskmoonBundler.Cache.put("/app.ts", 100, entry)
    assert DuskmoonBundler.Cache.get("/app.ts", 100) == entry
  end

  test "get_file returns an entry regardless of mtime" do
    entry = %{
      code: "const x = 1",
      sourcemap: nil,
      css: nil,
      content_type: "application/javascript"
    }

    DuskmoonBundler.Cache.put("/app.ts", 100, entry)
    assert DuskmoonBundler.Cache.get_file("/app.ts") == entry
  end

  test "different mtime is a miss" do
    entry = %{
      code: "const x = 1",
      sourcemap: nil,
      css: nil,
      content_type: "application/javascript"
    }

    DuskmoonBundler.Cache.put("/app.ts", 100, entry)
    assert DuskmoonBundler.Cache.get("/app.ts", 101) == nil
  end

  test "evict removes all entries for a path" do
    entry = %{code: "v1", sourcemap: nil, css: nil, content_type: "application/javascript"}
    DuskmoonBundler.Cache.put("/app.ts", 100, entry)
    DuskmoonBundler.Cache.put("/app.ts", 101, %{entry | code: "v2"})
    DuskmoonBundler.Cache.evict("/app.ts")
    assert DuskmoonBundler.Cache.get("/app.ts", 100) == nil
    assert DuskmoonBundler.Cache.get("/app.ts", 101) == nil
  end

  test "evict_file removes both plain and ?import entries" do
    entry = %{code: "v1", sourcemap: nil, css: nil, content_type: "text/css"}

    import_entry = %{
      code: "import_v1",
      sourcemap: nil,
      css: nil,
      content_type: "application/javascript"
    }

    DuskmoonBundler.Cache.put("/style.css", 100, entry)
    DuskmoonBundler.Cache.put("/style.css?import", 100, import_entry)
    DuskmoonBundler.Cache.evict_file("/style.css")
    assert DuskmoonBundler.Cache.get("/style.css", 100) == nil
    assert DuskmoonBundler.Cache.get("/style.css?import", 100) == nil
  end

  test "evict_file keeps entries of other files" do
    entry = %{code: "v1", sourcemap: nil, css: nil, content_type: "text/css"}

    DuskmoonBundler.Cache.put("/style.css", 100, entry)
    DuskmoonBundler.Cache.put("/style.css.map?import", 100, entry)
    DuskmoonBundler.Cache.put("/other.css?import", 100, entry)
    DuskmoonBundler.Cache.evict_file("/style.css")
    assert DuskmoonBundler.Cache.get("/style.css.map?import", 100) == entry
    assert DuskmoonBundler.Cache.get("/other.css?import", 100) == entry
  end

  test "get_file falls back to a variant entry" do
    entry = %{code: "v1", sourcemap: nil, css: nil, content_type: "text/css"}

    DuskmoonBundler.Cache.put("/style.css?import&vendor=abc", 100, entry)
    assert DuskmoonBundler.Cache.get_file("/style.css") == entry
    assert DuskmoonBundler.Cache.get_file("/other.css") == nil
  end

  test "file variants share a matchable key so file eviction needs no table scan" do
    entry = %{code: "v1", sourcemap: nil, css: nil, content_type: "text/css"}

    DuskmoonBundler.Cache.put("/style.css", 100, entry)
    DuskmoonBundler.Cache.put("/style.css?import", 100, entry)
    DuskmoonBundler.Cache.put("/other.css", 100, entry)

    assert length(:ets.match_object(:duskmoon_bundler_cache, {{"/style.css", :_}, :_})) == 2
  end

  test "evict_extension removes every variant of files with that extension" do
    entry = %{code: "v1", sourcemap: nil, css: nil, content_type: "text/css"}

    DuskmoonBundler.Cache.put("/style.css", 100, entry)
    DuskmoonBundler.Cache.put("/nested/other.css?import&vendor=abc", 100, entry)
    DuskmoonBundler.Cache.put("/app.ts?vendor=abc.css", 100, entry)
    DuskmoonBundler.Cache.evict_extension(".css")
    assert DuskmoonBundler.Cache.get("/style.css", 100) == nil
    assert DuskmoonBundler.Cache.get("/nested/other.css?import&vendor=abc", 100) == nil
    assert DuskmoonBundler.Cache.get("/app.ts?vendor=abc.css", 100) == entry
  end
end
