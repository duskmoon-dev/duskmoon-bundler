defmodule DuskmoonBundler.StylesheetExportsTest do
  use ExUnit.Case, async: true

  alias DuskmoonBundler.JS.Vendor
  alias DuskmoonBundler.Tailwind.Resolver

  @moduletag :tmp_dir

  test "vendor stylesheet lookup respects denied package exports", %{tmp_dir: dir} do
    modules = write_package(dir, %{"exports" => %{"./private.css" => nil}})

    assert Vendor.stylesheet_path("exports-fixture/private.css", node_modules: modules) == :error
  end

  test "vendor resolve directories respect denied package exports", %{tmp_dir: dir} do
    modules = write_package(dir, %{"exports" => %{"./private.css" => nil}})

    assert Vendor.stylesheet_path("exports-fixture/private.css", resolve_dirs: [modules]) ==
             :error
  end

  test "Tailwind stylesheet lookup respects denied subpath and root exports", %{tmp_dir: dir} do
    modules = write_package(dir, %{"exports" => %{"." => nil, "./private.css" => nil}})

    for id <- ["exports-fixture", "exports-fixture/private.css"] do
      assert_raise RuntimeError, ~r/Could not resolve stylesheet/, fn ->
        Resolver.resolve_stylesheet_path!(id, dir, modules)
      end
    end
  end

  test "Tailwind module lookup respects denied subpath and root exports", %{tmp_dir: dir} do
    modules = write_package(dir, %{"exports" => %{"." => nil, "./private.js" => nil}})

    for id <- ["exports-fixture", "exports-fixture/private.js"] do
      assert_raise RuntimeError, ~r/Could not resolve module/, fn ->
        Resolver.resolve_module_path!(id, dir, "module", modules)
      end
    end
  end

  test "unexported physical stylesheets are not exposed by fallback", %{tmp_dir: dir} do
    modules = write_package(dir, %{"exports" => %{"." => "./index.js"}})

    assert Vendor.stylesheet_path("exports-fixture/private.css", node_modules: modules) == :error

    assert_raise RuntimeError, ~r/Could not resolve stylesheet/, fn ->
      Resolver.resolve_stylesheet_path!("exports-fixture/private.css", dir, modules)
    end
  end

  test "an exports denial does not fall through to another copy of the package", %{tmp_dir: dir} do
    modules = write_package(dir, %{"exports" => %{"./private.css" => nil}})

    fallback_modules =
      write_package(Path.join(dir, "fallback"), %{
        "exports" => %{"./private.css" => "./private.css"}
      })

    assert Vendor.stylesheet_path("exports-fixture/private.css",
             node_modules: modules,
             resolve_dirs: [fallback_modules]
           ) == :error

    assert_raise RuntimeError, ~r/Could not resolve stylesheet/, fn ->
      Resolver.resolve_stylesheet_path!("exports-fixture/private.css", dir, fallback_modules)
    end
  end

  test "explicit stylesheet exports remain resolvable", %{tmp_dir: dir} do
    modules = write_package(dir, %{"exports" => %{"./public" => "./private.css"}})
    stylesheet = Path.join(modules, "exports-fixture/private.css")

    assert Vendor.stylesheet_path("exports-fixture/public", node_modules: modules) ==
             {:ok, stylesheet}

    assert Resolver.resolve_stylesheet_path!("exports-fixture/public", dir, modules) == stylesheet
  end

  test "packages without exports retain stylesheet subpaths and CSS main precedence", %{
    tmp_dir: dir
  } do
    modules =
      write_package(dir, %{"browser" => "index.js", "module" => "index.js", "main" => "index.css"})

    package = Path.join(modules, "exports-fixture")
    private_css = Path.join(package, "private.css")

    assert Vendor.stylesheet_path("exports-fixture/private.css", node_modules: modules) ==
             {:ok, private_css}

    assert Resolver.resolve_stylesheet_path!("exports-fixture/private.css", dir, modules) ==
             private_css

    assert Resolver.resolve_stylesheet_path!("exports-fixture", dir, modules) ==
             Path.join(package, "index.css")

    assert Resolver.resolve_module_path!("exports-fixture", dir, "module", modules) ==
             Path.join(package, "index.js")
  end

  test "package directories without manifests retain deep stylesheet resolution", %{tmp_dir: dir} do
    modules = write_package(dir, %{})
    File.rm!(Path.join(modules, "exports-fixture/package.json"))
    File.rm!(Path.join(modules, "exports-fixture/index.js"))
    File.rm!(Path.join(modules, "exports-fixture/index.css"))
    stylesheet = Path.join(modules, "exports-fixture/private.css")

    assert Vendor.stylesheet_path("exports-fixture/private.css", node_modules: modules) ==
             {:ok, stylesheet}

    assert Resolver.resolve_stylesheet_path!("exports-fixture/private.css", dir, modules) ==
             stylesheet
  end

  defp write_package(dir, metadata) do
    modules = Path.join(dir, "node_modules")
    package = Path.join(modules, "exports-fixture")
    File.mkdir_p!(package)

    File.write!(
      Path.join(package, "package.json"),
      JSON.encode!(Map.put(metadata, "name", "exports-fixture"))
    )

    for filename <- ["private.css", "private.js", "index.css", "index.js"] do
      File.write!(Path.join(package, filename), "")
    end

    modules
  end
end
