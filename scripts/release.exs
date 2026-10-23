Code.require_file("../.github/scripts/release_support.exs", __DIR__)

defmodule BundlerRelease do
  @moduledoc false
  def plan(version, sha) do
    ReleaseSupport.stable!(version)
    ReleaseSupport.checked_head!(sha)
    manifests = ReleaseSupport.manifests!("apps", ReleaseSupport.cohort(), version)

    %{
      version: version,
      source_sha: sha,
      source_dirty: ReleaseSupport.source_dirty?(),
      mix_lock_sha256: ReleaseSupport.digest("mix.lock"),
      bun_lock_sha256: ReleaseSupport.digest("bun.lock"),
      package_order: ReleaseSupport.dependency_order!(manifests),
      native_contract: %{rust_crates: 5, rust_targets: 8, quickbeam_targets: 7, total_assets: 47},
      steps: [
        "source tests",
        "pinned candidate UI source integration",
        "47 native artifacts",
        "checksums from final files",
        "stage and isolated consumer",
        "public immutable assets",
        "9 Hex packages",
        "registry glibc/musl consumers",
        "one pinned UI upgrade PR"
      ]
    }
  end

  def preflight(version, sha) do
    ReleaseSupport.clean_source!()
    plan = plan(version, sha)
    tag = "v#{version}"

    refs =
      ReleaseSupport.cmd!("git", [
        "ls-remote",
        "--tags",
        "https://github.com/duskmoon-dev/duskmoon-bundler.git",
        "refs/tags/#{tag}",
        "refs/tags/#{tag}^{}"
      ])

    if String.trim(refs) != "" do
      previous_sha =
        refs |> String.split("\n", trim: true) |> List.last() |> String.split() |> hd()

      ReleaseSupport.immutable_action(previous_sha, sha)
    end

    published = Enum.filter(ReleaseSupport.cohort(), &ReleaseSupport.exists_hex?(&1, version))

    if published != [] do
      path =
        Path.join(
          System.tmp_dir!(),
          "release-preflight-#{System.unique_integer([:positive])}.json"
        )

      try do
        ReleaseSupport.http!(
          "https://github.com/duskmoon-dev/duskmoon-bundler/releases/download/v#{version}/release-provenance.json",
          path
        )

        previous = JSON.decode!(File.read!(path))

        for key <- ~w(version source_sha mix_lock_sha256 bun_lock_sha256) do
          ReleaseSupport.immutable_action(
            previous[key],
            Map.fetch!(plan, String.to_existing_atom(key))
          )
        end

        IO.puts("Validated immutable partial/full release retry: #{inspect(published)}")
      after
        File.rm(path)
      end
    else
      IO.puts(
        "All nine registry versions are unpublished; final immutable asset gates remain required"
      )
    end
  end

  def prepare(version, sha, assets, output) do
    ReleaseSupport.clean_source!()
    provenance = plan(version, sha)
    output = Path.expand(output)

    ReleaseSupport.cmd!("elixir", [
      "scripts/stage-packages.exs",
      "--output",
      output,
      "--version",
      version
    ])
    |> IO.write()

    ReleaseSupport.cmd!("elixir", [
      ".github/scripts/generate_native_checksums.exs",
      version,
      Path.expand(assets),
      output
    ])
    |> IO.write()

    package_sources =
      Map.new(ReleaseSupport.cohort(), fn app ->
        root = Path.join(output, app)

        hashes =
          Path.wildcard(Path.join(root, "**/*"), match_dot: true)
          |> Enum.filter(&File.regular?/1)
          |> Map.new(&{Path.relative_to(&1, root), ReleaseSupport.digest(&1)})

        {app, hashes}
      end)

    packages = ReleaseSupport.manifests!(output, ReleaseSupport.cohort(), version)
    order = ReleaseSupport.dependency_order!(packages)

    for app <- order do
      dir = Path.join(output, app)
      # Package construction does not need to resolve unpublished registry siblings.
      ReleaseSupport.cmd!("mix", ["hex.build"], cd: dir) |> IO.write()
    end

    tarballs =
      Map.new(order, fn app ->
        {app, ReleaseSupport.digest(Path.join([output, app, "#{app}-#{version}.tar"]))}
      end)

    natives =
      Map.new(
        Path.wildcard(Path.join(assets, "*.tar.gz")),
        &{Path.basename(&1), ReleaseSupport.digest(&1)}
      )

    if map_size(natives) != 47, do: raise("expected complete 47-artifact cohort")

    provenance =
      Map.merge(provenance, %{
        package_order: order,
        package_tarballs: tarballs,
        package_sources: package_sources,
        native_assets: natives
      })

    File.write!(Path.join(output, "release-provenance.json"), JSON.encode!(provenance))
    IO.puts("Exact publish sources and provenance prepared without publishing")
  end

  def publish(version, sha, assets, output, packages?, opts \\ []) do
    ReleaseSupport.clean_source!()
    current = plan(version, sha)
    state = Path.join(output, "release-provenance.json") |> File.read!() |> JSON.decode!()

    for key <- ~w(version source_sha mix_lock_sha256 bun_lock_sha256) do
      unless Map.fetch!(state, key) == Map.fetch!(current, String.to_existing_atom(key)),
        do: raise("publication provenance mismatch: #{key}")
    end

    unless state["package_order"] == current.package_order and
             Enum.sort(Map.keys(state["package_tarballs"])) == Enum.sort(current.package_order) and
             Enum.sort(Map.keys(state["package_sources"])) == Enum.sort(current.package_order) and
             ReleaseSupport.reusable_native?(state),
           do: raise("publication requires the complete original package and native cohort")

    for {app, files} <- state["package_sources"], {name, hash} <- files do
      ReleaseSupport.immutable_action(ReleaseSupport.digest(Path.join([output, app, name])), hash)
    end

    native_files =
      Enum.map(state["native_assets"], fn {name, hash} ->
        path = Path.join(assets, name)
        ReleaseSupport.immutable_action(ReleaseSupport.digest(path), hash)
        path
      end)

    package_files =
      Enum.map(state["package_tarballs"], fn {app, hash} ->
        path = Path.join([output, app, "#{app}-#{version}.tar"])
        ReleaseSupport.immutable_action(ReleaseSupport.digest(path), hash)
        path
      end)

    checksum_files = Path.wildcard(Path.join([output, "*", "checksum-*.exs"]))
    # Public unauthenticated GETs of all final bytes succeed before any Hex publication.
    ReleaseSupport.public_release!(
      "duskmoon-dev/duskmoon-bundler",
      version,
      sha,
      native_files ++
        package_files ++ checksum_files ++ [Path.join(output, "release-provenance.json")],
      opts
    )

    if packages? do
      for app <- state["package_order"],
          do: ReleaseSupport.hex_publish!(app, version, Path.join(output, app))
    end

    if packages? do
      for app <- state["package_order"] do
        ReleaseSupport.verify_hex!(
          app,
          version,
          Path.join([output, app, "#{app}-#{version}.tar"])
        )
      end
    end

    IO.puts(
      "Full B cohort publication step complete; upgrade remains gated on clean registry and both musl consumer checks"
    )
  end
end

case System.argv() do
  ["plan", version, sha] ->
    IO.puts(JSON.encode!(BundlerRelease.plan(version, sha)))

  ["preflight", version, sha] ->
    BundlerRelease.preflight(version, sha)

  ["prepare", version, sha, assets, output] ->
    BundlerRelease.prepare(version, sha, assets, output)

  ["publish-assets", version, sha, assets, output] ->
    BundlerRelease.publish(version, sha, assets, output, false)

  ["publish-packages", version, sha, assets, output] ->
    BundlerRelease.publish(version, sha, assets, output, true)

  ["resume-packages", version, sha, assets, output] ->
    BundlerRelease.publish(version, sha, assets, output, true, existing_only: true)

  _ ->
    raise(
      "usage: elixir scripts/release.exs plan B SHA | prepare|publish-assets|publish-packages|resume-packages B SHA ASSETS STAGE"
    )
end
