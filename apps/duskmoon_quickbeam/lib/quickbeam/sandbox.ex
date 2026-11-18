defmodule QuickBEAM.Sandbox do
  @moduledoc false

  def options(opts) do
    case Keyword.get(opts, :sandbox, false) do
      false -> {:ok, opts}
      :strict -> strict_options(opts)
      value -> {:error, {:invalid_option, :sandbox, value}}
    end
  end

  defp strict_options(opts) do
    cond do
      Keyword.get(opts, :apis, false) not in [false, nil, []] ->
        {:error, {:sandbox_conflict, :apis}}

      not valid_handlers?(Keyword.get(opts, :handlers, %{})) ->
        {:error, {:sandbox_conflict, :handlers}}

      true ->
        {:ok, Keyword.put(opts, :apis, false)}
    end
  end

  defp valid_handlers?(handlers) when is_map(handlers) do
    Enum.all?(handlers, fn {name, handler} ->
      is_binary(name) and not String.starts_with?(name, "__") and valid_handler?(handler)
    end)
  end

  defp valid_handlers?(_), do: false
  defp valid_handler?({:with_caller, handler}), do: is_function(handler, 2)
  defp valid_handler?(handler), do: is_function(handler, 1)
end
