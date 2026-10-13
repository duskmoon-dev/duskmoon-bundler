Code.require_file("../.github/scripts/release_support.exs", __DIR__)

defmodule UpgradeUI do
  @moduledoc false
  @ui "duskmoon-dev/phoenix-duskmoon-ui"
  @bundler "duskmoon-dev/duskmoon-bundler"

  def run(version, sha, ui, evidence, push?) do
    ReleaseSupport.stable!(version)
    ReleaseSupport.sha!(sha)
    state = JSON.decode!(File.read!(evidence))

    unless ReleaseSupport.adoption_ready?(state),
      do: raise("partial or unverified toolchain release cannot initiate UI adoption")

    ReleaseSupport.immutable_action(state["version"], version)
    ReleaseSupport.immutable_action(state["source_sha"], sha)

    for app <- ReleaseSupport.cohort() do
      unless ReleaseSupport.exists_hex?(app, version),
        do: raise("missing registry cohort member #{app} #{version}")
    end

    provenance =
      Path.join(System.tmp_dir!(), "bundler-upgrade-#{System.unique_integer([:positive])}.json")

    try do
      ReleaseSupport.http!(
        "https://github.com/#{@bundler}/releases/download/v#{version}/release-provenance.json",
        provenance
      )

      remote = JSON.decode!(File.read!(provenance))
      ReleaseSupport.immutable_action(remote["source_sha"], sha)
      ReleaseSupport.immutable_action(remote["version"], version)
      # Independently check the entire immutable registry cohort against the release manifest.
      for app <- ReleaseSupport.cohort() do
        tar = provenance <> ".#{app}.tar"

        try do
          ReleaseSupport.http!("https://repo.hex.pm/tarballs/#{app}-#{version}.tar", tar)

          ReleaseSupport.immutable_action(
            ReleaseSupport.digest(tar),
            remote["package_tarballs"][app]
          )
        after
          File.rm(tar)
        end
      end

      File.cd!(Path.expand(ui), fn -> update(version, sha, push?) end)
    after
      File.rm(provenance)
    end
  end

  defp update(version, sha, push?) do
    origin = ReleaseSupport.cmd!("git", ["remote", "get-url", "origin"]) |> String.trim()

    unless origin in [
             "https://github.com/#{@ui}.git",
             "git@github.com:#{@ui}.git",
             "https://github.com/#{@ui}"
           ],
           do: raise("refusing unrelated UI origin")

    unless String.trim(ReleaseSupport.cmd!("git", ["status", "--porcelain"])) == "",
      do: raise("UI upgrade requires clean checkout")

    current = File.read!("BUNDLER_VERSION") |> String.trim() |> ReleaseSupport.stable!()

    if Version.compare(version, current) == :lt,
      do: raise("refusing toolchain downgrade #{current} -> #{version}")

    branch = "deps/bundler-v#{version}"
    metadata_path = "docs/bundler-upgrades/v#{version}.json"

    metadata = %{
      "version" => version,
      "source_sha" => sha,
      "release" => "https://github.com/#{@bundler}/releases/tag/v#{version}",
      "repository" => @bundler
    }

    if push? do
      refs =
        ReleaseSupport.cmd!("git", ["ls-remote", "--heads", "origin", "refs/heads/#{branch}"])

      if String.trim(refs) != "" do
        ReleaseSupport.cmd!("git", ["fetch", "origin", branch])

        existing =
          ReleaseSupport.cmd!("git", ["show", "FETCH_HEAD:#{metadata_path}"]) |> JSON.decode!()

        ReleaseSupport.immutable_action(existing, metadata)

        existing_pin =
          ReleaseSupport.cmd!("git", ["show", "FETCH_HEAD:BUNDLER_VERSION"]) |> String.trim()

        ReleaseSupport.immutable_action(existing_pin, version)

        {existing_lock, _} =
          ReleaseSupport.cmd!("git", ["show", "FETCH_HEAD:mix.lock"]) |> Code.eval_string()

        for app <- ReleaseSupport.cohort() do
          case existing_lock[app] || existing_lock[String.to_atom(app)] do
            {:hex, _, ^version, _, _, _, _, _} -> :ok
            other -> raise("existing upgrade lock cohort mismatch #{app}: #{inspect(other)}")
          end
        end

        # Reuse an existing branch; no force push or second commit on retries.
        ensure_pr(branch, version)
        IO.puts("Existing pinned UI upgrade reused")
        throw(:reused)
      end

      ReleaseSupport.cmd!("git", ["checkout", "-b", branch])
    end

    if current == version and File.exists?(metadata_path) do
      ReleaseSupport.immutable_action(JSON.decode!(File.read!(metadata_path)), metadata)
    else
      File.write!("BUNDLER_VERSION", version <> "\n")
      ReleaseSupport.cmd!("mix", ["deps.get"]) |> IO.write()
      ReleaseSupport.cmd!("elixir", ["scripts/check-toolchain.exs"]) |> IO.write()
      {lock, _} = Code.eval_file("mix.lock")

      for app <- ReleaseSupport.cohort() do
        case lock[app] || lock[String.to_atom(app)] do
          {:hex, _, ^version, _, _, _, _, _} -> :ok
          other -> raise("actual lock cohort mismatch #{app}: #{inspect(other)}")
        end
      end

      File.mkdir_p!(Path.dirname(metadata_path))
      File.write!(metadata_path, JSON.encode!(metadata) <> "\n")
    end

    if push? do
      ReleaseSupport.cmd!("git", ["config", "user.name", "duskmoon-bundler[bot]"])

      ReleaseSupport.cmd!("git", [
        "config",
        "user.email",
        "duskmoon-bundler[bot]@users.noreply.github.com"
      ])

      ReleaseSupport.cmd!("git", ["add", "BUNDLER_VERSION", "mix.lock", metadata_path])
      ReleaseSupport.cmd!("git", ["commit", "-m", "chore(deps): pin Duskmoon Bundler #{version}"])
      ReleaseSupport.cmd!("git", ["push", "origin", "HEAD:refs/heads/#{branch}"])
      ensure_pr(branch, version)
    else
      IO.puts("Local pinned upgrade ready for UI regression; no branch, push or PR created")
    end
  catch
    :reused -> :ok
  end

  defp ensure_pr(branch, version) do
    existing =
      ReleaseSupport.cmd!("gh", [
        "pr",
        "list",
        "--repo",
        @ui,
        "--head",
        branch,
        "--state",
        "all",
        "--json",
        "number,state"
      ])
      |> JSON.decode!()

    case existing do
      [] ->
        body = Path.join(System.tmp_dir!(), "bundler-pr-#{System.unique_integer([:positive])}.md")

        try do
          File.write!(
            body,
            "Pins all eight toolchain packages to verified B=#{version}, with the real Hex lock cohort and release provenance. UI assets, native loading, hooks, component/browser regressions and Storybook release checks must pass before review and merge. U remains independent.\n"
          )

          ReleaseSupport.cmd!("gh", [
            "pr",
            "create",
            "--repo",
            @ui,
            "--base",
            "main",
            "--head",
            branch,
            "--title",
            "chore(deps): pin Duskmoon Bundler #{version}",
            "--body-file",
            body
          ])
          |> IO.write()
        after
          File.rm(body)
        end

      [_] ->
        IO.puts("Existing UI PR reused")

      _ ->
        raise("multiple upgrade PRs for #{branch}; manual reconciliation required")
    end
  end
end

case System.argv() do
  [version, sha, ui, evidence] ->
    UpgradeUI.run(version, sha, ui, evidence, false)

  ["--push", version, sha, ui, evidence] ->
    UpgradeUI.run(version, sha, ui, evidence, true)

  _ ->
    raise("usage: elixir scripts/upgrade-ui.exs [--push] B SHA UI_CHECKOUT VERIFIED_RELEASE.json")
end
