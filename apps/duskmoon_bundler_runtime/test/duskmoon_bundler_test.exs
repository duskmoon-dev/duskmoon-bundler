defmodule DuskmoonBundlerTest do
  use ExUnit.Case, async: true
  doctest DuskmoonBundler

  defmodule DevEndpoint do
    def config(:code_reloader), do: true
  end

  defmodule ProdEndpoint do
    def config(:code_reloader), do: false
  end

  defmodule StaticEndpoint do
    def config(:code_reloader), do: false
    def static_path("/assets/js/app.js"), do: "/assets/js/app-digested.js?vsn=d"
    def static_path(path), do: path
  end

  test "static_path points at source entry in development" do
    assert DuskmoonBundler.static_path(DevEndpoint, "/assets/js/app.js",
             entry: "assets/js/app.tsx",
             root: "assets",
             prefix: "/assets"
           ) == "/assets/js/app.tsx"
  end

  test "static_path reads versioned production manifest" do
    outdir = tmp_dir("manifest")
    File.mkdir_p!(outdir)
    write_manifest(outdir, %{"app.js" => %{"file" => "app-deadbeef.js"}})

    assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js",
             entry: "assets/js/app.ts",
             outdir: outdir,
             prefix: "/assets"
           ) == "/assets/app-deadbeef.js"
  end

  test "static_path keeps backwards compatibility with flat production manifest" do
    outdir = tmp_dir("flat-manifest")
    File.mkdir_p!(outdir)

    File.write!(
      Path.join(outdir, "manifest.json"),
      JSON.encode!(%{"app.js" => %{"file" => "app-flat.js"}})
    )

    assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js",
             entry: "assets/js/app.ts",
             outdir: outdir,
             prefix: "/assets"
           ) == "/assets/app-flat.js"
  end

  test "static_path reads production manifest from build task js directory" do
    outdir = tmp_dir("manifest-js")
    js_outdir = Path.join(outdir, "js")
    File.mkdir_p!(js_outdir)
    write_manifest(js_outdir, %{"app.js" => %{"file" => "app-cafebabe.js"}})

    assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js",
             entry: "assets/js/app.ts",
             outdir: outdir,
             prefix: "/assets"
           ) == "/assets/js/app-cafebabe.js"
  end

  test "static_path prefers root manifest for backwards compatibility" do
    outdir = tmp_dir("manifest-precedence")
    js_outdir = Path.join(outdir, "js")
    File.mkdir_p!(js_outdir)
    write_manifest(outdir, %{"app.js" => %{"file" => "app-root.js"}})
    write_manifest(js_outdir, %{"app.js" => %{"file" => "app-js.js"}})

    assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js",
             entry: "assets/js/app.ts",
             outdir: outdir,
             prefix: "/assets"
           ) == "/assets/app-root.js"
  end

  test "static_path falls back to original path when manifest is missing" do
    outdir = tmp_dir("manifest-missing")

    assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js",
             entry: "assets/js/app.ts",
             outdir: outdir,
             prefix: "/assets"
           ) == "/assets/js/app.js"
  end

  test "static_path uses endpoint static_path for Phoenix digest lookup" do
    outdir = tmp_dir("manifest-static-path")
    js_outdir = Path.join(outdir, "js")
    File.mkdir_p!(js_outdir)
    write_manifest(js_outdir, %{"app.js" => %{"file" => "app.js"}})

    assert DuskmoonBundler.static_path(StaticEndpoint, "/assets/js/app.js",
             entry: "assets/js/app.ts",
             outdir: outdir,
             prefix: "/assets"
           ) == "/assets/js/app-digested.js?vsn=d"
  end

  test "static_path reads production manifest from build task css directory" do
    outdir = tmp_dir("manifest-css")
    css_outdir = Path.join(outdir, "css")
    File.mkdir_p!(css_outdir)
    write_manifest(css_outdir, %{"app.css" => %{"file" => "app-deadbeef.css"}})

    assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/css/app.css",
             outdir: outdir,
             prefix: "/assets"
           ) == "/assets/css/app-deadbeef.css"
  end

  test "static_path resolves asset entries from production manifests" do
    outdir = tmp_dir("manifest-image")
    js_outdir = Path.join(outdir, "js")
    File.mkdir_p!(js_outdir)
    write_manifest(js_outdir, %{"images/logo.svg" => %{"file" => "logo-deadbeef.svg"}})

    assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/images/logo.svg",
             outdir: outdir,
             prefix: "/assets"
           ) == "/assets/js/logo-deadbeef.svg"
  end

  describe "broken production manifests" do
    import ExUnit.CaptureLog

    test "static_path logs and falls back when the manifest is not valid JSON" do
      outdir = tmp_dir("manifest-invalid-json")
      File.mkdir_p!(outdir)
      manifest = Path.join(outdir, "manifest.json")
      File.write!(manifest, "{")

      log =
        capture_log(fn ->
          assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js",
                   outdir: outdir,
                   prefix: "/assets"
                 ) == "/assets/js/app.js"
        end)

      assert log =~ "[error]"
      assert log =~ "not valid JSON"
      assert log =~ manifest
    end

    test "static_path logs and falls back when the manifest version is unsupported" do
      outdir = tmp_dir("manifest-unsupported-version")
      File.mkdir_p!(outdir)

      File.write!(
        Path.join(outdir, "manifest.json"),
        JSON.encode!(%{"manifest_version" => 99, "entries" => %{}})
      )

      log =
        capture_log(fn ->
          assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js",
                   outdir: outdir,
                   prefix: "/assets"
                 ) == "/assets/js/app.js"
        end)

      assert log =~ "unsupported manifest_version 99"
    end

    test "static_path stays silent for a missing manifest or a missing asset" do
      missing = tmp_dir("manifest-silent-missing")
      outdir = tmp_dir("manifest-silent-asset")
      File.mkdir_p!(outdir)
      write_manifest(outdir, %{"app.js" => %{"file" => "app-deadbeef.js"}})

      log =
        capture_log(fn ->
          assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js",
                   outdir: missing,
                   prefix: "/assets"
                 ) == "/assets/js/app.js"

          assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/unknown-silent.js",
                   outdir: outdir,
                   prefix: "/assets"
                 ) == "/assets/js/unknown-silent.js"
        end)

      refute log =~ "manifest-silent"
      refute log =~ "unknown-silent"
    end
  end

  describe "manifest caching" do
    test "static_path reuses the parsed manifest while the file is unchanged" do
      outdir = tmp_dir("manifest-cache")
      File.mkdir_p!(outdir)
      write_manifest(outdir, %{"app.js" => %{"file" => "app-deadbeef.js"}})
      opts = [outdir: outdir, prefix: "/assets"]

      assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js", opts) ==
               "/assets/app-deadbeef.js"

      manifest = Path.join(outdir, "manifest.json")

      assert {content, %{"app.js" => %{"file" => "app-deadbeef.js"}}} =
               :persistent_term.get({DuskmoonBundler.StaticPath, :manifest, manifest}, nil)

      assert content == File.read!(manifest)

      assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js", opts) ==
               "/assets/app-deadbeef.js"
    end

    test "static_path picks up a rebuilt manifest" do
      outdir = tmp_dir("manifest-rebuilt")
      File.mkdir_p!(outdir)
      manifest = Path.join(outdir, "manifest.json")
      opts = [outdir: outdir, prefix: "/assets"]

      write_manifest(outdir, %{"app.js" => %{"file" => "app-deadbeef.js"}})
      File.touch!(manifest, {{2030, 1, 1}, {0, 0, 0}})

      assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js", opts) ==
               "/assets/app-deadbeef.js"

      # Same size, newer mtime.
      write_manifest(outdir, %{"app.js" => %{"file" => "app-cafebabe.js"}})
      File.touch!(manifest, {{2030, 1, 1}, {0, 0, 1}})

      assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js", opts) ==
               "/assets/app-cafebabe.js"

      # Same mtime, different size.
      write_manifest(outdir, %{"app.js" => %{"file" => "app-0123456789.js"}})
      File.touch!(manifest, {{2030, 1, 1}, {0, 0, 1}})

      assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js", opts) ==
               "/assets/app-0123456789.js"
    end

    test "static_path does not cache an unreadable manifest" do
      outdir = tmp_dir("manifest-recovered")
      File.mkdir_p!(outdir)
      manifest = Path.join(outdir, "manifest.json")
      opts = [outdir: outdir, prefix: "/assets"]
      content = DuskmoonBundler.Manifest.wrap(%{"app.js" => %{"file" => "app-deadbeef.js"}})
      encoded = JSON.encode!(content)

      File.write!(manifest, String.duplicate("{", byte_size(encoded)))
      File.touch!(manifest, {{2030, 1, 1}, {0, 0, 0}})

      ExUnit.CaptureLog.capture_log(fn ->
        assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js", opts) ==
                 "/assets/js/app.js"
      end)

      File.write!(manifest, encoded)
      File.touch!(manifest, {{2030, 1, 1}, {0, 0, 0}})

      assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js", opts) ==
               "/assets/app-deadbeef.js"
    end

    test "static_path detects same-size changes within the same timestamp" do
      outdir = tmp_dir("manifest-same-timestamp")
      File.mkdir_p!(outdir)
      manifest = Path.join(outdir, "manifest.json")
      opts = [outdir: outdir, prefix: "/assets"]
      timestamp = {{2030, 1, 1}, {0, 0, 0}}

      for {file, replace?} <- [
            {"app-deadbeef.js", false},
            {"app-cafebabe.js", false},
            {"app-feedface.js", true}
          ] do
        content = DuskmoonBundler.Manifest.wrap(%{"app.js" => %{"file" => file}})
        target = if replace?, do: manifest <> ".new", else: manifest
        File.write!(target, JSON.encode!(content))
        File.touch!(target, timestamp)
        if replace?, do: File.rename!(target, manifest)

        assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js", opts) ==
                 "/assets/" <> file
      end
    end

    test "a same-size corrupt replacement does not reuse cached valid entries" do
      outdir = tmp_dir("manifest-corrupt-replacement")
      File.mkdir_p!(outdir)
      manifest = Path.join(outdir, "manifest.json")
      opts = [outdir: outdir, prefix: "/assets"]
      write_manifest(outdir, %{"app.js" => %{"file" => "app-deadbeef.js"}})
      %{mtime: mtime, size: size} = File.stat!(manifest)

      assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js", opts) ==
               "/assets/app-deadbeef.js"

      File.write!(manifest, String.duplicate("{", size))
      File.touch!(manifest, mtime)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert DuskmoonBundler.static_path(ProdEndpoint, "/assets/js/app.js", opts) ==
                   "/assets/js/app.js"
        end)

      assert log =~ "not valid JSON"
    end
  end

  defp write_manifest(outdir, entries) do
    Path.join(outdir, "manifest.json")
    |> File.write!(DuskmoonBundler.Manifest.wrap(entries) |> JSON.encode!())
  end

  defp tmp_dir(name) do
    Path.join([
      System.tmp_dir!(),
      "duskmoon_bundler_runtime-test-#{System.unique_integer([:positive])}",
      name
    ])
  end
end
