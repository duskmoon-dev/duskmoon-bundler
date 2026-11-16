defmodule DuskmoonBundler.Builder.Externals do
  @moduledoc "Rewrite external imports into global variable access for production builds."

  alias DuskmoonBundler.Builder.Resolver

  @identifier_path ~r/^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$/
  @default_interop "((m) => m && m.__esModule ? m.default : m)"

  @doc """
  Rewrite external import declarations into direct global access.
  """
  def rewrite_imports(js_files, external_set, external_globals) do
    Enum.map(js_files, fn {label, code} ->
      {label, rewrite_imports_in_module(code, external_set, external_globals)}
    end)
  end

  defp rewrite_imports_in_module(code, external_set, external_globals) do
    case OXC.parse(code, "module.js") do
      {:ok, ast} ->
        {_ast, patches} =
          OXC.postwalk(ast, [], fn
            %{
              type: :import_declaration,
              source: %{value: spec},
              start: start_pos,
              end: end_pos,
              specifiers: specifiers
            } = node,
            patches ->
              if Resolver.external?(spec, external_set) do
                names = Enum.map(specifiers, &classify_specifier/1)
                global = Map.get(external_globals, spec, derive_global(spec))
                replacement = emit_global_access(global_access(global), names)
                patch = DuskmoonBundler.JS.Patch.new(start_pos, end_pos, replacement)
                {node, [patch | patches]}
              else
                {node, patches}
              end

            node, patches ->
              {node, patches}
          end)

        DuskmoonBundler.JS.Patch.apply(code, patches)

      {:error, _} ->
        code
    end
  end

  defp classify_specifier(%{
         type: :import_specifier,
         imported: %{name: name},
         local: %{name: local}
       }) do
    if name == local, do: {:named, name}, else: {:named, name, local}
  end

  defp classify_specifier(%{type: :import_default_specifier, local: %{name: name}}) do
    {:default, name}
  end

  defp classify_specifier(%{type: :import_namespace_specifier, local: %{name: name}}) do
    {:namespace, name}
  end

  defp classify_specifier(_), do: nil

  defp emit_global_access(global, names) do
    {named, others} =
      Enum.split_with(names, fn
        {:named, _} -> true
        {:named, _, _} -> true
        _ -> false
      end)

    named_part =
      if named != [] do
        destructured =
          named
          |> Enum.map(fn
            {:named, name} -> name
            {:named, name, local} -> [name, ": ", local]
          end)
          |> Enum.intersperse(", ")

        [["const { ", destructured, " } = ", global, ";"]]
      else
        []
      end

    other_parts =
      others
      |> Enum.map(fn
        {:default, name} -> ~s|const #{name} = #{@default_interop}(#{global});|
        {:namespace, name} -> ~s(const #{name} = #{global};)
        nil -> nil
      end)
      |> Enum.reject(&is_nil/1)

    [named_part, other_parts]
    |> Enum.concat()
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  # Reading through `globalThis` keeps a local binding that shares the global's
  # name (`import React from "react"`) from referencing itself.
  defp global_access(global) do
    if String.match?(global, @identifier_path), do: "globalThis." <> global, else: global
  end

  defp derive_global(specifier), do: DuskmoonBundler.Builder.derive_global_name(specifier)
end
