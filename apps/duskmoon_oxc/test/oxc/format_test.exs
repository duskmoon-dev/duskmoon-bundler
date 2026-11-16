defmodule OXC.FormatTest do
  use ExUnit.Case, async: true

  test "preserves caller formatting options for TypeScript" do
    assert {:ok, formatted} =
             OXC.Format.run("const value={name:\"Duskmoon\"};", "entry.ts",
               semi: false,
               single_quote: true,
               bracket_spacing: false
             )

    assert formatted == "const value = {name: 'Duskmoon'}\n"
  end

  test "formats JSX without changing its meaning" do
    assert {:ok, formatted} =
             OXC.Format.run("const view=<div title=\"Moon\">Hello</div>;", "entry.tsx")

    assert {:ok, ast} = OXC.parse(formatted, "formatted.tsx")
    assert %{body: [%{declarations: [%{init: %{type: :jsx_element}}]}]} = ast
    assert formatted =~ "title=\"Moon\""
  end

  test "returns parser errors for invalid source" do
    assert {:error, [_ | _]} = OXC.Format.run("const = ;", "invalid.js")
  end

  test "applies print and tab widths at the supported limits" do
    source = "function f(){return {alpha: 1, beta: 2}}"

    assert {:ok, "function f() {\n return { alpha: 1, beta: 2 };\n}\n"} =
             OXC.Format.run(source, "entry.js", print_width: 320, tab_width: 1)

    assert {:ok, formatted} = OXC.Format.run(source, "entry.js", print_width: 1, tab_width: 24)
    assert formatted =~ "\n" <> String.duplicate(" ", 24) <> "return {"
    assert formatted =~ "alpha: 1,\n"
  end

  test "rejects widths outside the supported ranges instead of truncating them" do
    source = "const x = {a: 1, b: 2}"

    for {option, value} <- [
          print_width: 0,
          print_width: 321,
          print_width: 65_556,
          print_width: "80",
          tab_width: -1,
          tab_width: 25,
          tab_width: 258,
          tab_width: 2.0
        ] do
      assert_raise ArgumentError, ~r/#{option}/, fn ->
        OXC.Format.run(source, "entry.js", [{option, value}])
      end
    end
  end
end
