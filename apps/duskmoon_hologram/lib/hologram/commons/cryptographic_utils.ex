defmodule Hologram.Commons.CryptographicUtils do
  @moduledoc false

  @doc """
  Calculates the cryptographic digest of the input data using the given algorithm (such as :md5, :sha256, etc.).
  Output format can be either `:hex` (hexadecimal string) or `:binary` (binary data).

  ## Examples

      iex> digest("Hologram", :sha256, :hex)
      "ddff15a2da596882cfd545132004c8e7355e457517a3874f4853cc6ff1110c2e"

      iex> digest("Hologram", false)
      <<221, 255, 21, 162, 218, 89, 104, 130, 207, 213, 69, 19, 32, 4, 200, 231, 53,
        94, 69, 117, 23, 163, 135, 79, 72, 83, 204, 111, 241, 17, 12, 46>>
  """
  @spec digest(binary, atom, :binary | :hex) :: String.t() | binary
  def digest(data, algo, format)

  def digest(data, algo, :binary) do
    :crypto.hash(algo, data)
  end

  def digest(data, algo, :hex) do
    data
    |> digest(algo, :binary)
    |> Base.encode16()
    |> String.downcase()
  end

  @doc """
  Generates a random UUID v4 in lowercase, hyphenated format.
  """
  @spec uuid4() :: String.t()
  def uuid4 do
    <<a::48, _version::4, b::12, _variant::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<part_1::binary-size(8), part_2::binary-size(4), part_3::binary-size(4),
      part_4::binary-size(4),
      part_5::binary-size(12)>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    Enum.join([part_1, part_2, part_3, part_4, part_5], "-")
  end
end
