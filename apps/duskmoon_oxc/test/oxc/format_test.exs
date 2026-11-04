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
end
