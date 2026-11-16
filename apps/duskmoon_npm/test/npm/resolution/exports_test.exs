defmodule NPM.Resolution.ExportsTest do
  use ExUnit.Case, async: true

  alias NPM.Resolution.{Exports, PackageResolver}

  test "overlapping component register patterns prefer the longer suffix in either declaration order" do
    entries = [
      {"./el-*", %{"import" => "./dist/esm/el-*/index.js"}},
      {"./el-*/register", %{"import" => "./dist/esm/el-*/register.js"}}
    ]

    for declarations <- [entries, Enum.reverse(entries)], component <- ["button", "alert"] do
      assert Exports.resolve(Map.new(declarations), "./el-#{component}/register", ["import"]) ==
               {:ok, "./dist/esm/el-#{component}/register.js"}
    end
  end

  test "longer prefixes take precedence over longer suffixes" do
    exports = %{
      "./features/*" => "./short/*.js",
      "./features/*/index" => "./suffix/*.js",
      "./features/internal/*" => "./prefix/*.js"
    }

    assert Exports.resolve(exports, "./features/internal/button/index") ==
             {:ok, "./prefix/button/index.js"}
  end

  test "exact exports take precedence and explicit nulls block wildcard fallback" do
    exports = %{
      "./*" => "./fallback/*.js",
      "./button" => "./exact.js",
      "./private" => nil,
      "./private/*" => nil
    }

    assert Exports.resolve(exports, "./button") == {:ok, "./exact.js"}
    assert Exports.resolve(exports, "./private") == :error
    assert Exports.resolve(exports, "./private/secret") == :error
  end

  test "an unmatched condition on the best pattern does not fall back to a broader pattern" do
    exports = %{
      "./*" => "./fallback/*.js",
      "./private/*" => %{"require" => "./require/*.cjs"}
    }

    assert Exports.resolve(exports, "./private/secret", ["import", "default"]) == :error
  end

  test "wildcard replacement removes a prefix and suffix exactly once" do
    assert Exports.resolve(%{"./*" => "./out/*"}, "././file") == {:ok, "./out/./file"}

    assert Exports.resolve(%{"./pre*end" => "./out/*"}, "./prepreendend") ==
             {:ok, "./out/preend"}

    assert Exports.resolve(%{"./x*xx" => "./out/*"}, "./xxx") == :error
    assert Exports.resolve(%{"./*/*" => "./out/*"}, "./a/b") == :error
  end

  @tag :tmp_dir
  test "resolves scoped component registration imports to existing files", %{tmp_dir: dir} do
    package_dir = Path.join(dir, "node_modules/@duskmoon-dev/elements")
    File.mkdir_p!(package_dir)

    File.write!(
      Path.join(package_dir, "package.json"),
      JSON.encode!(%{
        "name" => "@duskmoon-dev/elements",
        "type" => "module",
        "exports" => %{
          "./el-*" => %{"import" => "./dist/esm/el-*/index.js"},
          "./el-*/register" => %{"import" => "./dist/esm/el-*/register.js"}
        }
      })
    )

    for component <- ["button", "alert"] do
      target = Path.join(package_dir, "dist/esm/el-#{component}/register.js")
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, "export {};\n")

      assert PackageResolver.resolve("@duskmoon-dev/elements/el-#{component}/register", dir) ==
               {:ok, target}
    end
  end

  @tag :tmp_dir
  test "package resolution cannot bypass an export block using an existing private file", %{
    tmp_dir: dir
  } do
    package_dir = Path.join(dir, "node_modules/private-package")
    File.mkdir_p!(package_dir)
    File.write!(Path.join(package_dir, "secret.js"), "export {};\n")

    File.write!(
      Path.join(package_dir, "package.json"),
      JSON.encode!(%{"exports" => %{"./*" => "./*.js", "./secret" => nil}})
    )

    assert PackageResolver.resolve("private-package/secret", dir) == :error
  end
end
