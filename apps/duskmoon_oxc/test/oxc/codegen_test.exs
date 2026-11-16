defmodule OXC.CodegenTest do
  use ExUnit.Case, async: true

  # 2^63 and the largest double below 2^64: both exceed the signed 64-bit range.
  @large_integers ["9223372036854775808", "18446744073709549568"]

  test "round-trips integer literals between 2^63 and 2^64" do
    for source <- @large_integers do
      assert {:ok, ast} = OXC.parse("x = #{source}", "big.js")
      assert %{body: [%{expression: %{right: %{value: value}}}]} = ast
      assert is_integer(value) and value >= 9_223_372_036_854_775_808

      assert {:ok, code} = OXC.codegen(ast)

      assert {:ok, %{body: [%{expression: %{right: %{value: ^value}}}]}} =
               OXC.parse(code, "big.js")
    end
  end

  test "round-trips large integer object keys" do
    for source <- @large_integers do
      assert {:ok, ast} = OXC.parse("x = {#{source}: 1}", "big.js")
      assert %{body: [%{expression: %{right: %{properties: [%{key: %{value: value}}]}}}]} = ast

      assert {:ok, code} = OXC.codegen(ast)

      assert {:ok, %{body: [%{expression: %{right: %{properties: [%{key: %{value: ^value}}]}}}]}} =
               OXC.parse(code, "big.js")
    end
  end

  test "generates numeric_literal nodes from floats and integers" do
    assert {:ok, "42;\n"} = OXC.codegen(numeric_literal(42))
    assert {:ok, "1.5;\n"} = OXC.codegen(numeric_literal(1.5))

    value = 9_223_372_036_854_775_808
    assert {:ok, code} = OXC.codegen(numeric_literal(value))
    assert {:ok, %{body: [%{expression: %{value: parsed}}]}} = OXC.parse(code, "big.js")
    assert parsed == 9_223_372_036_854_776_000
  end

  test "rejects numeric_literal nodes without a numeric value" do
    assert {:error, [%{message: message}]} = OXC.codegen(numeric_literal("abc"))
    assert message =~ "numeric"
  end

  defp numeric_literal(value) do
    %{
      type: :program,
      body: [
        %{type: :expression_statement, expression: %{type: :numeric_literal, value: value}}
      ]
    }
  end
end
