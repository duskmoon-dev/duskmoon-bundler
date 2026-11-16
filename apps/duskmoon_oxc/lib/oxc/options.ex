defmodule OXC.Options do
  @moduledoc false

  # Validates option values the native layer would otherwise silently replace
  # with a default.

  @formats ~w(iife esm cjs)
  @jsx_runtimes ~w(automatic classic)

  @spec format!(term()) :: String.t()
  def format!(format), do: one_of!(:format, format, @formats)

  @spec jsx!(term()) :: String.t()
  def jsx!(runtime), do: one_of!(:jsx, runtime, @jsx_runtimes)

  @spec target!(term()) :: String.t()
  def target!(nil), do: ""
  def target!(target) when is_binary(target), do: target

  def target!(target) when is_atom(target) and not is_boolean(target),
    do: Atom.to_string(target)

  def target!(target) do
    raise ArgumentError,
          "invalid :target option #{inspect(target)}; expected a string or atom such as \"es2020\""
  end

  @spec define!(term()) :: map()
  def define!(define) when is_map(define) and not is_struct(define) do
    Enum.each(define, fn
      {key, value}
      when (is_binary(key) or is_atom(key)) and
             (is_binary(value) or (is_atom(value) and not is_nil(value))) ->
        :ok

      {key, value} ->
        raise ArgumentError,
              "invalid :define entry #{inspect(key)} => #{inspect(value)}; " <>
                "expected a JavaScript expression string such as ~s(\"production\")"
    end)

    define
  end

  def define!(define) do
    raise ArgumentError, "invalid :define option #{inspect(define)}; expected a map"
  end

  defp one_of!(option, value, allowed) do
    string =
      cond do
        is_binary(value) -> value
        is_atom(value) and not is_nil(value) -> Atom.to_string(value)
        true -> nil
      end

    if string in allowed do
      string
    else
      expected = Enum.map_join(allowed, ", ", &inspect(String.to_atom(&1)))

      raise ArgumentError,
            "invalid #{inspect(option)} option #{inspect(value)}; expected one of #{expected}"
    end
  end
end
