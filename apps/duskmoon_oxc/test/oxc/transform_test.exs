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
end
