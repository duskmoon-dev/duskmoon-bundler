defmodule Vize.ErrorContractTest do
  use ExUnit.Case, async: true

  test "legacy SFC operations retain string errors and RuntimeError bang exceptions" do
    source = "<template>one</template><template>two</template>"

    for {operation, bang} <- [
          {&Vize.parse_sfc/1, &Vize.parse_sfc!/1},
          {&Vize.compile_sfc/1, &Vize.compile_sfc!/1},
          {&Vize.generate_dts/1, &Vize.generate_dts!/1}
        ] do
      assert {:error, message} = operation.(source)
      assert message =~ "SFC can only contain one <template> block"
      assert_raise RuntimeError, fn -> bang.(source) end
    end

    assert {:error, %Vize.Error{diagnostics: [%Vize.Diagnostic{message: message}]}} =
             Vize.analyze_sfc(source)

    assert message =~ "SFC can only contain one <template> block"
    assert_raise Vize.Error, fn -> Vize.analyze_sfc!(source) end
  end

  test "legacy CSS operations report errors in successful result maps" do
    for {operation, bang, input} <- [
          {&Vize.CSS.compile/1, &Vize.CSS.compile!/1, "}"},
          {&Vize.CSS.parse_ast/1, &Vize.CSS.parse_ast!/1, "}"},
          {&Vize.CSS.print_ast/1, &Vize.CSS.print_ast!/1, %{}}
        ] do
      assert {:ok, %{errors: [_ | _] = errors}} = operation.(input)
      assert Enum.all?(errors, &is_binary/1)
      assert_raise RuntimeError, fn -> bang.(input) end
    end
  end

  test "CSS URL operations return and raise structured Vize errors" do
    assert {:error, %Vize.Error{errors: [_ | _]}} = Vize.CSS.collect_urls("}")
    assert {:error, %Vize.Error{errors: [_ | _]}} = Vize.CSS.rewrite_urls("}", fn _ -> :keep end)
    assert_raise Vize.Error, fn -> Vize.CSS.collect_urls!("}") end
    assert_raise Vize.Error, fn -> Vize.CSS.rewrite_urls!("}", fn _ -> :keep end) end
  end
end
