defmodule DuskmoonBundler.Builder.ResolverTest do
  use ExUnit.Case, async: true

  alias DuskmoonBundler.Builder.{Context, Resolver}

  @moduletag :tmp_dir

  test "does not resolve physical subpaths denied by package exports", %{tmp_dir: dir} do
    package_dir = Path.join([dir, "node_modules", "fixture"])
    File.mkdir_p!(package_dir)

    File.write!(
      Path.join(package_dir, "package.json"),
      Jason.encode!(%{
        "name" => "fixture",
        "exports" => %{"." => "./index.js", "./private" => nil}
      })
    )

    File.write!(Path.join(package_dir, "index.js"), "export default 'public';")
    File.write!(Path.join(package_dir, "private.js"), "export default 'private';")
    File.write!(Path.join(package_dir, "unexported.js"), "export default 'unexported';")

    for subpath <- ["private", "unexported"] do
      specifier = "fixture/" <> subpath

      assert {:error, {:not_found, ^specifier}} =
               Resolver.resolve(specifier, Path.join(dir, "app.js"), %Context{})
    end
  end

  test "keeps an export mapped to the main file when a physical subpath also exists", %{
    tmp_dir: dir
  } do
    package_dir = Path.join([dir, "node_modules", "fixture"])
    File.mkdir_p!(package_dir)

    File.write!(
      Path.join(package_dir, "package.json"),
      Jason.encode!(%{
        "name" => "fixture",
        "exports" => %{"." => "./index.js", "./feature" => "./index.js"}
      })
    )

    entry = Path.join(package_dir, "index.js")
    File.write!(entry, "export default 'exported';")
    File.write!(Path.join(package_dir, "feature.js"), "export default 'unexported';")

    assert {:ok, ^entry} =
             Resolver.resolve("fixture/feature", Path.join(dir, "app.js"), %Context{})
  end

  test "does not bypass the first configured package's exports using another directory", %{
    tmp_dir: dir
  } do
    first = Path.join(dir, "first")
    second = Path.join(dir, "second")

    for base <- [first, second] do
      package_dir = Path.join(base, "fixture")
      File.mkdir_p!(package_dir)

      File.write!(
        Path.join(package_dir, "package.json"),
        Jason.encode!(%{
          "name" => "fixture",
          "exports" => %{"./private" => if(base == first, do: nil, else: "./private.js")}
        })
      )

      File.write!(Path.join(package_dir, "private.js"), "export default 'private';")
    end

    assert {:error, {:not_found, "fixture/private"}} =
             Resolver.resolve("fixture/private", Path.join(dir, "app.js"), %Context{
               resolve_dirs: [first, second]
             })
  end

  test "preserves direct subpath resolution for missing manifests", %{tmp_dir: dir} do
    package_dir = Path.join([dir, "node_modules", "fixture"])
    File.mkdir_p!(package_dir)
    entry = Path.join(package_dir, "feature.js")
    File.write!(entry, "export default 'feature';")

    assert {:ok, ^entry} =
             Resolver.resolve("fixture/feature", Path.join(dir, "app.js"), %Context{})

    File.write!(Path.join(package_dir, "index.js"), "export default 'root';")

    assert {:ok, ^entry} =
             Resolver.resolve("fixture/feature", Path.join(dir, "app.js"), %Context{})
  end
end
