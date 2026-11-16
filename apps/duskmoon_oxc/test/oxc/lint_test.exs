defmodule OXC.LintTest do
  use ExUnit.Case, async: true

  test "preserves configured rule severity and source spans" do
    source = "debugger;"

    assert {:ok,
            [
              %{
                rule: "eslint(no-debugger)",
                severity: :deny,
                span: {0, 9},
                message: message
              }
            ]} = OXC.Lint.run(source, "entry.js", rules: %{"no-debugger" => :deny})

    assert message =~ "debugger"
  end

  test "allows callers to disable a built-in rule" do
    assert {:ok, []} =
             OXC.Lint.run("debugger;", "entry.js", rules: %{"no-debugger" => :allow})
  end

  test "returns parser errors for invalid source" do
    assert {:error, [_ | _]} = OXC.Lint.run("const = ;", "invalid.js")
  end

  test "reports the configured severity for plugins with hyphenated display names" do
    cases = [
      {:jsx_a11y, "jsx-a11y/alt-text", "jsx-a11y(alt-text)",
       ~s|export const A = () => <img src="a.png" />;|},
      {:react_perf, "react-perf/jsx-no-new-object-as-prop",
       "react-perf(jsx-no-new-object-as-prop)", ~s|export const A = () => <Item style={{}} />;|},
      {:nextjs, "nextjs/no-img-element", "next(no-img-element)",
       ~s|export const A = () => <img src="a.png" alt="a" />;|}
    ]

    for {plugin, rule, reported, source} <- cases, severity <- [:deny, :warn] do
      assert {:ok, diagnostics} =
               OXC.Lint.run(source, "entry.jsx", plugins: [plugin], rules: %{rule => severity})

      assert %{severity: ^severity} = Enum.find(diagnostics, &(&1.rule == reported)),
             "expected #{reported} to be reported as #{severity}, got: #{inspect(diagnostics)}"
    end
  end
end
