defmodule NPM.Packager do
  @moduledoc """
  Package file and size inspection using the same selection as `NPM.Pack`,
  `mix npm.pack` and `mix npm.publish`.
  """

  @doc "List files selected for the publish tarball."
  @spec files_to_pack(String.t()) :: [String.t()]
  def files_to_pack(dir \\ ".") do
    case NPM.Pack.list_files(dir) do
      {:ok, files} -> files
      {:error, _reason} -> []
    end
  end

  @doc "Calculate the total unpacked size of selected files."
  @spec pack_size(String.t()) :: non_neg_integer()
  def pack_size(dir \\ ".") do
    files_to_pack(dir)
    |> Enum.reduce(0, fn file, total ->
      case File.stat(Path.join(dir, file)) do
        {:ok, %{size: size}} -> total + size
        {:error, _reason} -> total
      end
    end)
  end

  @doc "Count selected package files."
  @spec pack_file_count(String.t()) :: non_neg_integer()
  def pack_file_count(dir \\ "."), do: length(files_to_pack(dir))
end
