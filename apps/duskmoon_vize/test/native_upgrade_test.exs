defmodule Vize.NativeUpgradeTest do
  use ExUnit.Case, async: true

  test "SFC compilation preserves scripts, scoped styles, and declaration generation" do
    source = """
    <script setup lang="ts">
    defineProps<{ message: string }>()
    </script>
    <template><div class="message">{{ message }}</div></template>
    <style scoped>.message { color: red }</style>
    """

    assert {:ok, %{code: code, css: css, errors: [], template_hash: template_hash}} =
             Vize.compile_sfc(source, filename: "Message.vue", strip_types: true)

    assert code =~ "message"
    assert css =~ "data-v-"
    assert is_binary(template_hash)
    assert {:ok, %{dts: declaration}} = Vize.generate_dts(source, filename: "Message.vue")
    assert declaration =~ "message"
  end

  test "CSS AST round trips through the upgraded native CSS engine" do
    source = ".message { color: red; background: url('./message.svg') }"

    assert {:ok, %{ast: ast, errors: []}} = Vize.CSS.parse_ast(source)
    assert {:ok, %{code: code, errors: []}} = Vize.CSS.print_ast(ast, minify: true)
    assert code =~ "color:red"
    assert code =~ "message.svg"

    assert {:ok, [%{url: "./message.svg", start: start, end: finish}]} =
             Vize.CSS.select(source, :urls)

    assert binary_part(source, start, finish - start) == "./message.svg"
  end

  test "Vapor diagnostics retain source slices and multiline UTF-16 positions" do
    source = "<div>\n  😀<span id=\"first\" id=\"second\"></span>\n</div>"
    assert {:ok, result} = Vize.compile_vapor(source, diagnostics: true)

    assert %Vize.Diagnostic{location: location, recoverable?: true} =
             Enum.find(result.diagnostics, &(&1.code == "DuplicateAttribute"))

    assert location.start.line == 2

    assert location.source ==
             binary_part(
               source,
               location.start.offset,
               location.end.offset - location.start.offset
             )

    prefix = binary_part(source, 0, location.start.offset) |> String.split("\n") |> List.last()

    utf16_column =
      div(byte_size(:unicode.characters_to_binary(prefix, :utf8, {:utf16, :little})), 2) + 1

    assert location.start.column == utf16_column
  end

  test "Vapor IR preserves ordered object and literal prop sources" do
    assert {:ok, %{block: block}} =
             Vize.vapor_ir(~s(<div class="fixed" v-bind="attrs" :id="id" />))

    assert %{sources: sources} =
             Enum.find(operations(block), &(&1.kind == :set_merged_props))

    assert Enum.any?(sources, &match?(%{kind: :object, value: "attrs"}, &1))
    assert Enum.any?(sources, &match?(%{kind: :group, props: [_ | _]}, &1))
  end

  test "Vapor component props retain model operands and event modifier semantics" do
    source = ~s(<Widget v-model.trim="name" @save.stop.once="save" />)
    assert {:ok, %{block: block}} = Vize.vapor_ir(source)
    assert %{props: props} = Enum.find(operations(block), &(&1.kind == :create_component))

    assert %{key: {:static_, "modelValue"}, values: ["name"], value_kind: :expression} =
             Enum.find(props, &(&1.key == {:static_, "modelValue"}))

    assert %{values: ["name"], value_kind: :model_update} =
             Enum.find(props, &(&1.key == {:static_, "onUpdate:modelValue"}))

    assert %{values: [modifiers], value_kind: :model_modifiers} =
             Enum.find(props, &(&1.key == {:static_, "modelModifiers"}))

    assert modifiers =~ ~s("trim": true)

    assert %{handler_modifiers: %{non_keys: ["stop"], options: %{once: true}}} =
             Enum.find(props, &(&1.key == {:static_, "onSave"}))

    assert {:ok, %{code: code}} = Vize.compile_vapor(source)
    assert code =~ "onUpdate:modelValue"
    assert code =~ "$event =>"
    assert code =~ "= $event"
    assert code =~ "withModifiers"
  end

  test "Vapor IR distinguishes append indexes from sibling node anchors" do
    assert {:ok, %{block: appended}} = Vize.vapor_ir("<div><Widget /></div>")

    assert %{anchor: nil, anchor_index: 0} =
             Enum.find(operations(appended), &(&1.kind == :create_component))

    assert {:ok, %{block: before_sibling}} =
             Vize.vapor_ir("<div><Widget /><span>after</span></div>")

    assert %{anchor: anchor, anchor_index: nil} =
             Enum.find(operations(before_sibling), &(&1.kind == :create_component))

    assert is_integer(anchor)
  end

  test "Vapor split retains keyed sub-blocks and merged attribute sources" do
    assert {:ok, %{slots: [%{kind: :key, value: "identity", render: render}]}} =
             Vize.vapor_split("<div :key=\"identity\">{{ message }}</div>")

    assert render.statics == ["<div>", "</div>"]
    assert render.slots == [%{kind: :set_text, values: ["message"]}]

    assert {:ok, %{statics: ["<div", "></div>"], slots: [slot]}} =
             Vize.vapor_split(~s(<div class="fixed" v-bind="attrs" :id="id" />))

    assert %{kind: :set_merged_props, sources: sources} = slot
    assert Enum.any?(sources, &match?(%{kind: :object, value: "attrs"}, &1))
  end

  test "template and Vapor entry points return transform diagnostics" do
    for compile <- [&Vize.compile_template/1, &Vize.vapor_ir/1, &Vize.vapor_split/1] do
      assert {:error, errors} = compile.("<div v-if>missing condition</div>")
      assert errors != []
      assert Enum.all?(errors, &is_binary/1)
    end
  end

  test "manual compilation entry points accept Vue self-closing elements with recovery diagnostics" do
    for compile <- [&Vize.compile_template/1, &Vize.vapor_ir/1, &Vize.vapor_split/1] do
      assert {:ok, %{diagnostics: diagnostics}} = compile.("<div />")

      assert %{code: "ExtendPoint", recoverable: true, location: %{source: "<div />"}} =
               Enum.find(diagnostics, &(&1.code == "ExtendPoint"))
    end
  end

  test "manual compilation entry points continue to reject fatal parser errors" do
    for compile <- [&Vize.compile_template/1, &Vize.vapor_ir/1, &Vize.vapor_split/1] do
      assert {:error, errors} = compile.("<div></span>")
      assert errors != []
      assert Enum.all?(errors, &is_binary/1)
    end
  end

  defp operations(block), do: block.operations ++ List.flatten(block.effects)

  test "deeply nested templates do not overflow the scheduler stack" do
    depth = 2_000

    template =
      String.duplicate("<div>", depth) <> "{{ msg }}" <> String.duplicate("</div>", depth)

    assert {status, _} = Vize.compile_template(template)
    assert status in [:ok, :error]

    assert {status, _} = Vize.compile_sfc("<template>#{template}</template>")
    assert status in [:ok, :error]
  end
end
