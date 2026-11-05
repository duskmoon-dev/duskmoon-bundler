defmodule NativeDownloadSupport do
  @moduledoc false

  @backends [:RustlerPrecompiled, :ZiglerPrecompiled]

  def overlay_url!(published, candidate) do
    {_, [base_url]} =
      Macro.prewalk(Code.string_to_quoted!(candidate), [], fn
        {:use, _, [{:__aliases__, _, [backend]}, options]} = node, urls
        when backend in @backends ->
          {node, [Keyword.fetch!(options, :base_url) | urls]}

        node, urls ->
          {node, urls}
      end)

    {patched, 1} =
      Macro.prewalk(Code.string_to_quoted!(published), 0, fn
        {:use, metadata, [{:__aliases__, _, [backend]} = module, options]}, count
        when backend in @backends ->
          options = Keyword.replace!(options, :base_url, base_url)
          {{:use, metadata, [module, options]}, count + 1}

        node, count ->
          {node, count}
      end)

    patched
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end
end
