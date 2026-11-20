defmodule NPM.Cache do
  alias NPM.Registry.URL
  alias NPM.Security.RegistryPolicy

  @complete_marker ".npm-ex-cache-complete"

  @moduledoc """
  Global package cache.

  Downloaded packages are stored in `~/.npm_ex/cache/<name>/<version>/`
  and reused across projects. The cache is populated on first install
  and checked before downloading from the registry.
  """

  @doc "Root directory of the global cache."
  @spec dir :: String.t()
  def dir do
    NPM.Config.cache_dir()
  end

  @doc """
  Path to a specific package version in the cache.

  Raises `ArgumentError` when the name or version is not safe to use as a
  cache path (see `validate_package/2`).
  """
  @spec package_dir(String.t(), String.t()) :: String.t()
  def package_dir(name, version) do
    case validate_package(name, version) do
      :ok -> contained_package_dir!(name, version)
      {:error, reason} -> raise ArgumentError, "unsafe cache entry: #{inspect(reason)}"
    end
  end

  defp contained_package_dir!(name, version) do
    root = Path.expand(Path.join(dir(), "cache"))
    path = Path.expand(Path.join([root, name, version]))

    if String.starts_with?(path, root <> "/") do
      path
    else
      raise ArgumentError, "cache path escapes cache root: #{inspect({name, version})}"
    end
  end

  @doc """
  Validate that a package name and version are safe cache/install path segments.

  The name must be an installable npm name and the version a strict semver.
  """
  @spec validate_package(term(), term()) ::
          :ok
          | {:error, {:invalid_package_name, term()}}
          | {:error, {:invalid_package_version, term(), term()}}
  def validate_package(name, version) do
    cond do
      not NPM.Scope.installable_name?(name) -> {:error, {:invalid_package_name, name}}
      not valid_version?(version) -> {:error, {:invalid_package_version, name, version}}
      true -> :ok
    end
  end

  @doc "Whether `version` is a strict, untrimmed semver string."
  @spec valid_version?(term()) :: boolean()
  def valid_version?(version) when is_binary(version) do
    version == String.trim(version) and match?({:ok, _}, NPMSemver.Version.parse(version))
  end

  def valid_version?(_version), do: false

  @doc "Check if a package version is already cached."
  @spec cached?(String.t(), String.t()) :: boolean()
  def cached?(name, version) do
    validate_package(name, version) == :ok and cache_intact?(package_dir(name, version))
  end

  @doc """
  Check if a package version is cached and was verified against an integrity
  that satisfies `integrity` (see `NPM.Tarball.integrity_satisfied?/2`).
  """
  @spec cached?(String.t(), String.t(), String.t() | nil) :: boolean()
  def cached?(name, version, integrity) do
    cached?(name, version) and
      NPM.Tarball.integrity_satisfied?(recorded_integrity(package_dir(name, version)), integrity)
  end

  @doc """
  Ensure a package version is in the cache.

  Downloads and extracts the tarball if not already cached. A cached copy is
  reused only when the integrity recorded at download time satisfies
  `integrity`; otherwise it is re-downloaded and verified.
  Returns `{:ok, cache_path}`, `{:ok, :missing_optional}` when an
  optional package fails to fetch, or `{:error, reason}`.

  ## Options

    * `:optional?` - a failed fetch yields `{:ok, :missing_optional}`.
    * `:unpacked_size` - the registry-declared `dist.unpackedSize`; a value over
      `NPM.Config.max_unpacked_bytes/0` is rejected before downloading.
  """
  @spec ensure(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:ok, :missing_optional} | {:error, term()}
  def ensure(name, version, tarball_url, integrity, opts \\ []) do
    with :ok <- validate_package(name, version) do
      with_lock(name, version, fn ->
        ensure_locked(name, version, tarball_url, integrity, opts)
      end)
    end
  end

  defp ensure_locked(name, version, tarball_url, integrity, opts) do
    dest = package_dir(name, version)

    cond do
      cached?(name, version, integrity) ->
        {:ok, dest}

      oversized?(opts[:unpacked_size]) ->
        {:error, {:unpacked_too_large, name, version, opts[:unpacked_size]}}

      true ->
        fetch_locked(name, version, tarball_url, integrity, dest, opts)
    end
  end

  # `dist.unpackedSize` is registry-declared, so this is only an early exit;
  # `NPM.Tarball.extract/2` enforces the limit on the real data.
  defp oversized?(size), do: is_integer(size) and size > NPM.Config.max_unpacked_bytes()

  # The package is extracted and marked complete in a temporary directory next
  # to `dest` and then renamed into place, so `dest` is never observed half
  # written, including by other OS processes sharing the cache (the lock only
  # covers this VM).
  defp fetch_locked(name, version, tarball_url, integrity, dest, opts) do
    registry = NPM.Config.registry_for(name)
    tmp = temp_dir(dest)

    try do
      RegistryPolicy.validate_url!(tarball_url)
      File.mkdir_p!(Path.dirname(dest))

      case fetch_and_extract(
             candidate_tarball_urls(name, version, tarball_url, integrity),
             integrity,
             tmp,
             registry
           ) do
        {:ok, _count} ->
          write_complete_marker!(tmp, integrity)
          promote(tmp, dest, name, version, integrity)

        {:error, reason} ->
          handle_fetch_error({:fetch_failed, name, version, reason}, opts)
      end
    rescue
      error in RegistryPolicy.Error ->
        handle_fetch_error(error, opts)
    after
      File.rm_rf(tmp)
    end
  end

  defp temp_dir(dest) do
    suffix = "#{System.pid()}-#{System.unique_integer([:positive])}"
    Path.join(Path.dirname(dest), ".tmp-#{Path.basename(dest)}-#{suffix}")
  end

  defp promote(tmp, dest, name, version, integrity) do
    cond do
      File.rename(tmp, dest) == :ok ->
        {:ok, dest}

      # Another process completed the same entry first; keep theirs.
      cached?(name, version, integrity) ->
        {:ok, dest}

      true ->
        replace_stale(tmp, dest, name, version, integrity)
    end
  end

  # `dest` holds an interrupted extraction or an entry verified against a
  # different integrity. Move it aside rather than deleting it in place.
  defp replace_stale(tmp, dest, name, version, integrity) do
    stale = tmp <> "-stale"

    result =
      with :ok <- File.rename(dest, stale),
           :ok <- File.rename(tmp, dest) do
        {:ok, dest}
      else
        {:error, reason} ->
          if cached?(name, version, integrity),
            do: {:ok, dest},
            else: {:error, {:cache_write_failed, name, version, reason}}
      end

    File.rm_rf(stale)
    result
  end

  @doc false
  @spec __candidate_tarball_urls__(String.t(), String.t(), String.t(), String.t()) :: [String.t()]
  def __candidate_tarball_urls__(name, version, tarball_url, integrity) do
    candidate_tarball_urls(name, version, tarball_url, integrity)
  end

  defp fetch_and_extract([], _integrity, _dest, _registry), do: {:error, :no_tarball_url}

  defp fetch_and_extract([tarball_url | fallback_urls], integrity, dest, registry) do
    RegistryPolicy.validate_url!(tarball_url)

    case NPM.Tarball.fetch_and_extract(tarball_url, integrity, dest, registry: registry) do
      {:ok, _count} = ok ->
        ok

      {:error, reason} when fallback_urls != [] ->
        File.rm_rf(dest)

        Mix.shell().error(
          "tarball fetch failed for #{tarball_url}, trying fallback #{hd(fallback_urls)}: #{inspect(reason)}"
        )

        fetch_and_extract(fallback_urls, integrity, dest, registry)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp candidate_tarball_urls(_name, _version, tarball_url, integrity)
       when integrity in [nil, ""] do
    [tarball_url]
  end

  defp candidate_tarball_urls(name, version, tarball_url, _integrity) do
    if NPM.Config.scope_registry(name) do
      # A package bound to a scope registry is never requested from another one.
      [tarball_url]
    else
      original_origin = RegistryPolicy.origin(tarball_url)

      NPM.Config.allowed_registries()
      |> Enum.map(fn registry ->
        if RegistryPolicy.origin(registry) == original_origin do
          tarball_url
        else
          URL.tarball_url(name, version, registry)
        end
      end)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
    end
  end

  defp handle_fetch_error(reason, opts) do
    if Keyword.get(opts, :optional?, false) do
      {:ok, :missing_optional}
    else
      {:error, reason}
    end
  end

  defp with_lock(name, version, fun) do
    :global.trans(lock_id(name, version), fun, [node()], :infinity)
  end

  @doc false
  def __lock_id__(name, version, requester \\ self()) do
    lock_id(name, version, requester)
  end

  defp lock_id(name, version, requester \\ self()) do
    {{__MODULE__, name, version}, requester}
  end

  # The marker records the integrity the tarball was verified against so later
  # cache hits can be checked against the integrity the caller expects.
  defp write_complete_marker!(dest, integrity) do
    File.write!(Path.join(dest, @complete_marker), "1\n#{integrity || ""}\n")
  end

  defp recorded_integrity(dest) do
    case File.read(Path.join(dest, @complete_marker)) do
      {:ok, content} -> content |> String.split("\n") |> Enum.at(1, "") |> String.trim()
      {:error, _} -> ""
    end
  end

  defp complete_marker?(dest) do
    File.regular?(Path.join(dest, @complete_marker))
  end

  defp cache_intact?(dest) do
    File.regular?(Path.join(dest, "package.json")) and complete_marker?(dest)
  end
end
