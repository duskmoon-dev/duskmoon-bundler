defmodule OXC.Format do
  @moduledoc """
  Format JavaScript/TypeScript source code with oxfmt.

  Prettier-compatible formatter built on OXC, ~30× faster than Prettier.
  Supports JS, JSX, TS, and TSX.

  ## Examples

      {:ok, formatted} = OXC.Format.run("const x=1;let   y =  2;", "test.js")
      # "const x = 1;\nlet y = 2;\n"

      {:ok, formatted} = OXC.Format.run("const x=1", "test.js", semi: false)
      # "const x = 1\n"
  """

  alias OXC.Format.Native

  @type sort_imports_opts :: %{
          optional(:ignore_case) => boolean(),
          optional(:sort_side_effects) => boolean(),
          optional(:order) => :asc | :desc,
          optional(:newlines_between) => boolean(),
          optional(:partition_by_newline) => boolean(),
          optional(:partition_by_comment) => boolean(),
          optional(:internal_pattern) => [String.t()]
        }

  @type option ::
          {:print_width, 1..320}
          | {:tab_width, 0..24}
          | {:use_tabs, boolean()}
          | {:semi, boolean()}
          | {:single_quote, boolean()}
          | {:jsx_single_quote, boolean()}
          | {:trailing_comma, :all | :none}
          | {:bracket_spacing, boolean()}
          | {:bracket_same_line, boolean()}
          | {:arrow_parens, :always | :avoid}
          | {:end_of_line, :lf | :crlf | :cr}
          | {:quote_props, :as_needed | :consistent | :preserve}
          | {:single_attribute_per_line, boolean()}
          | {:object_wrap, :preserve | :collapse}
          | {:experimental_operator_position, :start | :end}
          | {:experimental_ternaries, boolean()}
          | {:sort_imports, boolean() | sort_imports_opts()}

  @doc """
  Format source code.

  ## Options

    * `:print_width` — line width, `1..320` (default: 100)
    * `:tab_width` — spaces per indentation level, `0..24` (default: 2)
    * `:use_tabs` — indent with tabs instead of spaces (default: false)
    * `:semi` — print semicolons (default: true)
    * `:single_quote` — use single quotes (default: false)
    * `:jsx_single_quote` — use single quotes in JSX (default: false)
    * `:trailing_comma` — `:all` or `:none` (default: `:all`)
    * `:bracket_spacing` — spaces inside object braces (default: true)
    * `:bracket_same_line` — put `>` on the same line (default: false)
    * `:arrow_parens` — `:always` or `:avoid` (default: `:always`)
    * `:end_of_line` — `:lf`, `:crlf`, or `:cr` (default: `:lf`)
    * `:quote_props` — `:as_needed`, `:consistent`, or `:preserve` (default: `:as_needed`)
    * `:single_attribute_per_line` — force one attribute per line in JSX (default: false)
    * `:object_wrap` — `:preserve` or `:collapse` (default: `:preserve`)
    * `:experimental_operator_position` — `:start` or `:end` (default: `:end`)
    * `:experimental_ternaries` — use curious ternaries (default: false)
    * `:sort_imports` — `true` for defaults, or a map with sub-options:
      * `:ignore_case` — case-insensitive sorting (default: true)
      * `:sort_side_effects` — sort side-effect imports (default: false)
      * `:order` — `:asc` or `:desc` (default: `:asc`)
      * `:newlines_between` — blank lines between groups (default: true)
      * `:partition_by_newline` — partition by existing newlines (default: false)
      * `:partition_by_comment` — partition by comments (default: false)
      * `:internal_pattern` — prefixes for internal imports (default: `["~/", "@/"]`)

  Raises `ArgumentError` when `:print_width` or `:tab_width` is not an integer
  in its supported range.

  ## Examples

      iex> {:ok, code} = OXC.Format.run("const   x=1", "test.js")
      iex> code
      "const x = 1;\\n"

      iex> {:ok, code} = OXC.Format.run("const x=1", "test.js", semi: false)
      iex> code
      "const x = 1\\n"

      iex> {:ok, code} = OXC.Format.run("const x = {a: 1, b: 2}", "test.js", print_width: 20)
      iex> String.contains?(code, "\\n")
      true
  """
  @spec run(iodata(), String.t(), [option()]) ::
          {:ok, String.t()} | {:error, [String.t()]}
  def run(source, filename, opts \\ []) do
    opts_map =
      opts
      |> Map.new()
      |> Map.new(fn
        {:print_width, v} ->
          {:print_width, integer_in_range!(:print_width, v, 1..320)}

        {:tab_width, v} ->
          {:tab_width, integer_in_range!(:tab_width, v, 0..24)}

        {k, v}
        when is_atom(v) and
               k in [
                 :trailing_comma,
                 :arrow_parens,
                 :end_of_line,
                 :object_wrap,
                 :experimental_operator_position,
                 :embedded_language_formatting
               ] ->
          {k, to_string(v)}

        {:quote_props, v} ->
          {:quote_props, String.replace(to_string(v), "_", "-")}

        {:sort_imports, %{} = m} ->
          {:sort_imports,
           Map.new(m, fn
             {:order, v} -> {:order, to_string(v)}
             pair -> pair
           end)}

        {:sort_tailwindcss, %{} = m} ->
          {:sort_tailwindcss, m}

        {k, v} ->
          {k, v}
      end)

    Native.format(source, filename, opts_map)
  end

  # The native formatter narrows these to u16/u8, so out-of-range values would
  # wrap around or be dropped instead of failing.
  defp integer_in_range!(_option, value, first..last//_)
       when is_integer(value) and value >= first and value <= last,
       do: value

  defp integer_in_range!(option, value, range) do
    raise ArgumentError,
          "invalid #{inspect(option)} option #{inspect(value)}; expected an integer in #{inspect(range)}"
  end

  @doc """
  Like `run/3` but raises on errors.

  ## Examples

      iex> OXC.Format.run!("const   x=1", "test.js")
      "const x = 1;\\n"
  """
  @spec run!(iodata(), String.t(), [option()]) :: String.t()
  def run!(source, filename, opts \\ []) do
    case run(source, filename, opts) do
      {:ok, code} ->
        code

      {:error, errors} ->
        raise OXC.Error, message: "OXC format error: #{inspect(errors)}", errors: errors
    end
  end
end
