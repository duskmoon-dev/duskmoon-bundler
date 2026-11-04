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
end
