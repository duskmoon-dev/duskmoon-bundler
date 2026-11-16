defmodule NPM.Ignore do
  @moduledoc """
  Parses .npmignore and .gitignore files for package publishing.

  Determines which files to include/exclude when packing or publishing
  a package, following npm's ignore rules.
  """

  @always_ignored ~w(.git .svn CVS .hg .DS_Store node_modules .npmrc)
  @never_ignored ~w(package.json README.md LICENSE LICENCE CHANGELOG.md)

  @doc """
  Reads and parses an ignore file.
  """
  @spec read(String.t()) :: [String.t()]
  def read(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      _ -> []
    end
  end

  @doc """
  Parses ignore file content into a list of patterns.
  """
  @spec parse(String.t()) :: [String.t()]
  def parse(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&comment_or_blank?(&1))
  end

  @doc """
  Checks if a file path is ignored by the given patterns.
  """
  @spec ignored?(String.t(), [String.t()], boolean()) :: boolean()
  def ignored?(path, patterns, initially_ignored \\ false) do
    basename = Path.basename(path)

    cond do
      always_ignored?(basename) ->
        true

      never_ignored?(basename) ->
        false

      true ->
        apply_rules(path, patterns, initially_ignored)
    end
  end

  @doc false
  def apply_rules(path, patterns, initially_ignored \\ false, directory? \\ false) do
    Enum.reduce(patterns, initially_ignored, fn
      "!" <> pattern, ignored ->
        if matches?(path, pattern, false, directory?), do: false, else: ignored

      pattern, ignored ->
        if matches?(path, pattern, false, directory?), do: true, else: ignored
    end)
  end

  @doc """
  Returns the list of always-ignored paths.
  """
  @spec always_ignored :: [String.t()]
  def always_ignored, do: @always_ignored

  @doc """
  Returns the list of never-ignored paths.
  """
  @spec never_ignored :: [String.t()]
  def never_ignored, do: @never_ignored

  @doc """
  Gets the effective ignore patterns for a package directory.

  Checks .npmignore first, falls back to .gitignore.
  """
  @spec effective_patterns(String.t()) :: [String.t()]
  def effective_patterns(package_dir) do
    npmignore = Path.join(package_dir, ".npmignore")
    gitignore = Path.join(package_dir, ".gitignore")

    if File.regular?(npmignore), do: read(npmignore), else: read(gitignore)
  end

  defp always_ignored?(name), do: name in @always_ignored

  defp never_ignored?(name) do
    downcased = String.downcase(name)
    Enum.any?(@never_ignored, &(String.downcase(&1) == downcased))
  end

  defp comment_or_blank?(line) do
    line == "" or String.starts_with?(line, "#")
  end

  @doc false
  def matches?(path, pattern, anchored? \\ false, directory? \\ false) do
    anchored? =
      anchored? or String.starts_with?(pattern, "/") or
        String.contains?(String.trim_trailing(pattern, "/"), "/")

    directory_pattern? = String.ends_with?(pattern, "/")

    pattern =
      pattern
      |> String.replace_prefix("./", "")
      |> String.trim_leading("/")
      |> String.trim_trailing("/")

    prefix = if anchored?, do: "^", else: "(?:^|/)"
    suffix = if directory_pattern? and not directory?, do: "/.*$", else: "(?:/.*)?$"
    expression = prefix <> glob_regex(pattern) <> suffix

    case Regex.compile(expression) do
      {:ok, regex} -> Regex.match?(regex, path)
      {:error, _invalid_pattern} -> false
    end
  end

  defp glob_regex("**/" <> rest), do: "(?:.*/)?" <> glob_regex(rest)
  defp glob_regex("**" <> rest), do: ".*" <> glob_regex(rest)
  defp glob_regex("*" <> rest), do: "[^/]*" <> glob_regex(rest)
  defp glob_regex("?" <> rest), do: "[^/]" <> glob_regex(rest)

  defp glob_regex("\\" <> rest) do
    case String.next_grapheme(rest) do
      nil -> Regex.escape("\\")
      {char, tail} -> Regex.escape(char) <> glob_regex(tail)
    end
  end

  defp glob_regex("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [class, tail] when class != "" ->
        class = String.replace_prefix(class, "!", "^")
        "[" <> class <> "]" <> glob_regex(tail)

      _ ->
        "\\[" <> glob_regex(rest)
    end
  end

  defp glob_regex(""), do: ""

  defp glob_regex(pattern) do
    {char, rest} = String.next_grapheme(pattern)
    Regex.escape(char) <> glob_regex(rest)
  end
end
