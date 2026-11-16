defmodule DuskmoonBundler.HTMLEntry do
  @moduledoc """
  Extract entry points from HTML files.

  Parses `<script src="...">` and `<link rel="stylesheet" href="...">` tags
  using LazyHTML to discover JS and CSS entry files.

  ## Example

      # index.html
      <script type="module" src="js/app.ts"></script>
      <link rel="stylesheet" href="css/app.css">

      {:ok, entries} = DuskmoonBundler.HTMLEntry.extract("index.html")
      entries.scripts  #=> ["js/app.ts"]
      entries.styles   #=> ["css/app.css"]
  """

  @doc """
  Extract script and stylesheet entries from an HTML file.

  Relative paths are resolved against the HTML file's directory, which is also
  the root for root-absolute paths such as `/src/main.ts`. Remote, protocol-relative
  and other scheme URLs are not local entries and are ignored.
  """
  @spec extract(String.t()) ::
          {:ok, %{scripts: [String.t()], styles: [String.t()]}}
          | {:error, {:file_read_error, String.t(), File.posix()}}
  def extract(html_path) do
    html_path = Path.expand(html_path)

    case File.read(html_path) do
      {:ok, html} ->
        doc = LazyHTML.from_document(html)

        {:ok,
         %{
           scripts: local_paths(doc, "script[src]", "src", html_path),
           styles: local_paths(doc, ~s(link[rel="stylesheet"][href]), "href", html_path)
         }}

      {:error, reason} ->
        {:error, {:file_read_error, html_path, reason}}
    end
  end

  defp local_paths(doc, selector, attribute, html_path) do
    doc
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
    |> Enum.reject(&remote?/1)
    |> Enum.map(&resolve_path(&1, html_path))
  end

  @doc "Check if a path is an HTML file."
  @spec html?(String.t()) :: boolean()
  def html?(path), do: Path.extname(path) in ~w(.html .htm)

  defp remote?(src) do
    String.starts_with?(src, "//") or URI.parse(src).scheme != nil
  end

  defp resolve_path(src, html_path) do
    html_path |> Path.dirname() |> Path.join(String.trim_leading(src, "/")) |> Path.expand()
  end
end
