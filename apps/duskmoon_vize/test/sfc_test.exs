defmodule Vize.SFCTest do
  use ExUnit.Case, async: true

  @source """
  <template><div class="red">{{ msg }}</div></template>
  <script>export default { name: "Message" }</script>
  <script setup lang="ts">const msg: string = "hello"</script>
  <style scoped>.red { color: red }</style>
  <style module="classes" lang="scss">.blue { color: blue }</style>
  <i18n lang="json">{"en": {}}</i18n>
  """

  describe "parse_sfc/1" do
    test "returns every block with its content, language, and source range" do
      assert {:ok, descriptor} = Vize.parse_sfc(@source)

      assert %{content: ~s(<div class="red">{{ msg }}</div>), lang: nil} = descriptor.template
      assert %{content: ~s(export default { name: "Message" })} = descriptor.script

      assert %{content: ~s(const msg: string = "hello"), lang: "ts", setup: true} =
               descriptor.script_setup

      assert [
               %{content: ".red { color: red }", scoped: true, lang: nil},
               %{content: ".blue { color: blue }", scoped: false, lang: "scss", module: "classes"}
             ] = descriptor.styles

      assert [%{content: ~s({"en": {}}), block_type: "i18n", attrs: %{"lang" => "json"}}] =
               descriptor.custom_blocks

      for block <- [descriptor.template, descriptor.script_setup | descriptor.styles] do
        assert binary_part(@source, block.loc.start, block.loc.end - block.loc.start) ==
                 block.content
      end
    end

    test "returns nil and empty lists for absent blocks" do
      assert {:ok, descriptor} = Vize.parse_sfc("<template><p>only</p></template>")

      assert %{script: nil, script_setup: nil, styles: [], custom_blocks: []} = descriptor

      assert %{template: %{content: "<p>only</p>"}} =
               Vize.parse_sfc!("<template><p>only</p></template>")
    end
  end

  describe "compile_ssr/1" do
    test "generates a push-based render function and its helper imports" do
      assert {:ok, %{code: code, preamble: preamble}} =
               Vize.compile_ssr(~s(<div :id="id">{{ msg }}</div>))

      assert code =~ "function ssrRender(_ctx, _push"
      assert code =~ "_ssrInterpolate(_ctx.msg)"
      assert code =~ "_ctx.id"
      assert preamble =~ ~s(from "@vue/server-renderer")
      assert preamble =~ "ssrInterpolate as _ssrInterpolate"
      assert %{code: ^code} = Vize.compile_ssr!(~s(<div :id="id">{{ msg }}</div>))
    end

    test "returns template errors as strings" do
      assert {:error, [_ | _] = errors} = Vize.compile_ssr("<div></span>")
      assert Enum.all?(errors, &is_binary/1)

      assert_raise RuntimeError, ~r/SSR compile error/, fn ->
        Vize.compile_ssr!("<div></span>")
      end
    end
  end

  describe "vapor_split/1" do
    test "returns an atom-keyed split" do
      assert {:ok, split} = Vize.vapor_split(~s(<div :class="cls"><p>{{ msg }}</p></div>))

      assert split |> Map.keys() |> Enum.sort() ==
               [:diagnostics, :element_template_map, :slots, :statics, :templates]

      assert split.statics == [~s(<div class="), ~s("><p>), "</p></div>"]

      assert split.slots == [
               %{kind: :set_prop, values: ["cls"]},
               %{kind: :set_text, values: ["msg"]}
             ]
    end
  end
end
