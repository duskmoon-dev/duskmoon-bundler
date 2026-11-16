defmodule OXC.TransformTest do
  use ExUnit.Case, async: true

  test "replaces global defines while preserving local bindings and literal text" do
    source = """
    export const mode: string = process.env.NODE_ENV
    export function read(process: any) { return process.env.NODE_ENV }
    console.log('process.env.NODE_ENV')
    """

    assert {:ok, code} =
             OXC.transform(source, "env.ts",
               define: %{"process.env.NODE_ENV" => ~s("development")}
             )

    assert code =~ ~s(export const mode = "development")
    assert code =~ "return process.env.NODE_ENV"
    assert code =~ ~s("process.env.NODE_ENV")
  end

  test "preserves imported bindings and module boundaries" do
    source = "import process from './process.js'; export const mode = process.env.NODE_ENV"

    assert {:ok, code} =
             OXC.transform(source, "env.js",
               define: %{"process.env.NODE_ENV" => ~s("development")}
             )

    assert code =~ ~s(import process from "./process.js")
    assert code =~ "export const mode = process.env.NODE_ENV"
  end

  test "applies defines in batched transformations" do
    assert [
             {:ok, first},
             {:ok, second}
           ] =
             OXC.transform_many(
               [
                 {"export const mode = process.env.NODE_ENV", "first.js"},
                 {"export const mode: string = process.env.NODE_ENV", "second.ts"}
               ],
               define: %{"process.env.NODE_ENV" => ~s("development")}
             )

    assert first =~ ~s(export const mode = "development")
    assert second =~ ~s(export const mode = "development")
  end

  test "returns diagnostics for an invalid define expression" do
    assert {:error, [_ | _]} =
             OXC.transform("export const mode = process.env.NODE_ENV", "env.js",
               define: %{"process.env.NODE_ENV" => "("}
             )
  end

  test "source map results contain exactly the documented keys" do
    assert {:ok, result} = OXC.transform("const x: number = 1", "entry.ts", sourcemap: true)
    assert result |> Map.keys() |> Enum.sort() == [:code, :sourcemap]
    assert result.code == "const x = 1;\n"
    assert %{"version" => 3, "sources" => ["entry.ts"]} = Jason.decode!(result.sourcemap)

    assert [{:ok, many}] =
             OXC.transform_many([{"const x: number = 1", "entry.ts"}], sourcemap: true)

    assert many == result
  end

  test "stringifies atom define values" do
    assert {:ok, "console.log(true, null);\n"} =
             OXC.transform("console.log(DEBUG, EMPTY)", "entry.js",
               define: %{"DEBUG" => true, EMPTY: :null}
             )
  end

  test "rejects define values that are not JavaScript source strings" do
    for value <- [1, 1.5, nil, ["1"], %{}] do
      assert_raise ArgumentError, ~r/:define.*"B"/s, fn ->
        OXC.transform("console.log(A, B)", "entry.js", define: %{"A" => "1", "B" => value})
      end

      assert_raise ArgumentError, ~r/:define/, fn ->
        OXC.transform_many([{"console.log(A, B)", "entry.js"}], define: %{"B" => value})
      end
    end

    assert_raise ArgumentError, ~r/:define/, fn ->
      OXC.transform("console.log(A)", "entry.js", define: [{"A", "1"}])
    end
  end

  test "rejects unknown JSX runtimes" do
    assert {:ok, automatic} = OXC.transform("<a />", "entry.jsx", jsx: :automatic)
    assert {:ok, ^automatic} = OXC.transform("<a />", "entry.jsx", jsx: "automatic")
    assert {:ok, classic} = OXC.transform("<a />", "entry.jsx", jsx: "classic")
    assert classic =~ "createElement"

    for runtime <- [:preserve, "react", nil, 1] do
      assert_raise ArgumentError, ~r/:jsx/, fn ->
        OXC.transform("<a />", "entry.jsx", jsx: runtime)
      end
    end
  end

  test "downlevels for string, atom, and list targets" do
    source = "export const x = a ?? b"

    for target <- ["es2019", :es2019, "es2019,chrome70"] do
      assert {:ok, code} = OXC.transform(source, "entry.js", target: target)
      refute code =~ "??"
    end

    for unset <- ["", nil] do
      assert {:ok, code} = OXC.transform(source, "entry.js", target: unset)
      assert code =~ "??"
    end
  end

  test "reports invalid targets instead of silently skipping downleveling" do
    source = "export const x = a ?? b"

    assert {:error, [%{message: message}]} = OXC.transform(source, "entry.js", target: "nope")
    assert message =~ "nope"

    assert [{:error, [%{message: ^message}]}] =
             OXC.transform_many([{source, "entry.js"}], target: "nope")

    for target <- [2019, true, ["es2019"]] do
      assert_raise ArgumentError, ~r/:target/, fn ->
        OXC.transform(source, "entry.js", target: target)
      end
    end
  end

  test "rewrites static, re-export, and dynamic import specifiers" do
    source =
      ~s|import a from 'a'; export * from "b"; const c = import('c'); export { d } from 'd';|

    assert {:ok, rewritten} =
             OXC.rewrite_specifiers(source, "entry.js", fn
               "b" -> :keep
               specifier -> {:rewrite, ["/vendor/", specifier, ".js"]}
             end)

    assert rewritten ==
             ~s|import a from '/vendor/a.js'; export * from "b"; const c = import('/vendor/c.js'); export { d } from '/vendor/d.js';|

    assert OXC.rewrite_specifiers!(["import 'é';", " import 'x'"], "entry.js", fn
             "x" -> {:rewrite, "y"}
             _ -> :keep
           end) == "import 'é'; import 'y'"

    assert {:error, [%{message: _} | _]} =
             OXC.rewrite_specifiers("import from", "entry.js", fn _ -> :keep end)
  end

  test "minifies with and without mangling" do
    source = "export function increment(longName) { if (false) { unused() } return longName + 1 }"

    assert {:ok, mangled} = OXC.minify(source, "entry.js")
    refute mangled =~ "longName"
    refute mangled =~ "unused"

    assert {:ok, "export function increment(longName){return longName+1}"} =
             OXC.minify(source, "entry.js", mangle: false)

    assert {:error, [%{message: _} | _]} = OXC.minify("const = ;", "entry.js")
    assert_raise OXC.Error, fn -> OXC.minify!("const = ;", "entry.js") end
  end
end
