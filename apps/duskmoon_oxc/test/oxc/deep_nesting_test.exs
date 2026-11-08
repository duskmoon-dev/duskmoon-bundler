defmodule OXC.DeepNestingTest do
  use ExUnit.Case, async: true

  # Deep enough to overflow the ~320 KiB dirty scheduler stack, which used to
  # kill the VM; the NIFs now run recursive work on a large-stack thread.
  @depth 5_000

  defp nested_array(depth),
    do: String.duplicate("[", depth) <> "1" <> String.duplicate("]", depth)

  defp nested_parens(depth),
    do: String.duplicate("(", depth) <> "1" <> String.duplicate(")", depth)

  defp source,
    do:
      "export const value = #{nested_array(@depth)};\nexport const p = #{nested_parens(@depth)};\n"

  test "parse and codegen survive deeply nested input" do
    assert {:ok, ast} = OXC.parse(source(), "deep.js")
    assert {:ok, code} = OXC.codegen(ast)
    assert is_binary(code)
  end

  test "valid?, transform, transform_many and minify survive deeply nested input" do
    assert OXC.valid?(source(), "deep.js")
    assert {:ok, _} = OXC.transform(source(), "deep.js")
    assert [{:ok, _}, {:ok, _}] = OXC.transform_many([{source(), "a.js"}, {source(), "b.js"}])
    assert {:ok, _} = OXC.minify(source(), "deep.js")
  end

  test "format and lint survive deeply nested input" do
    assert {status, _} = OXC.Format.run(source(), "deep.js")
    assert status in [:ok, :error]

    assert {:ok, _} = OXC.Lint.run(source(), "deep.js")
  end
end
