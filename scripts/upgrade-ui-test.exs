Code.require_file("../.github/scripts/release_support.exs", __DIR__)
ExUnit.start()

defmodule UpgradeUIRetryTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @version "10.0.3"
  @sha String.duplicate("a", 40)

  setup %{tmp_dir: tmp_dir} do
    tmp_dir = Path.expand(tmp_dir)
    ui = Path.join(tmp_dir, "ui")
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(Path.join(ui, "docs/bundler-upgrades"))
    File.mkdir_p!(bin)
    File.write!(Path.join(ui, "BUNDLER_VERSION"), @version <> "\n")

    metadata = %{
      "version" => @version,
      "source_sha" => @sha,
      "release" => "https://github.com/duskmoon-dev/duskmoon-bundler/releases/tag/v#{@version}",
      "repository" => "duskmoon-dev/duskmoon-bundler"
    }

    metadata_path = Path.join(ui, "docs/bundler-upgrades/v#{@version}.json")
    File.write!(metadata_path, JSON.encode!(metadata) <> "\n")

    lock =
      Map.new(ReleaseSupport.ui_cohort(), fn app ->
        package = String.to_atom(app)
        {package, {:hex, package, @version, "checksum", [:mix], [], "hexpm", "outer"}}
      end)

    File.write!(Path.join(ui, "mix.lock"), inspect(lock) <> "\n")
    git = System.find_executable("git")
    git!(git, ui, ["init", "--initial-branch=main"])

    git!(git, ui, [
      "remote",
      "add",
      "origin",
      "https://github.com/duskmoon-dev/phoenix-duskmoon-ui.git"
    ])

    commit!(git, ui)

    evidence = Path.join(tmp_dir, "evidence.json")

    File.write!(
      evidence,
      JSON.encode!(%{
        "version" => @version,
        "source_sha" => @sha,
        "packages" => ReleaseSupport.cohort(),
        "public_assets_verified" => true,
        "registry_consumer_verified" => true,
        "musl_amd64_verified" => true,
        "musl_arm64_verified" => true
      })
    )

    tar = Path.join(tmp_dir, "registry.tar")
    File.write!(tar, "isolated registry byte-verification fixture")
    provenance = Path.join(tmp_dir, "provenance.json")

    File.write!(
      provenance,
      JSON.encode!(%{
        "version" => @version,
        "source_sha" => @sha,
        "package_tarballs" => Map.new(ReleaseSupport.cohort(), &{&1, ReleaseSupport.digest(tar)})
      })
    )

    executable!(Path.join(bin, "curl"), """
    #!/bin/sh
    output=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output) output="$2"; shift 2 ;;
        *) url="$1"; shift ;;
      esac
    done
    case "$url" in
      https://hex.pm/api/packages/*/releases/10.0.3) ;;
      https://github.com/duskmoon-dev/duskmoon-bundler/releases/download/v10.0.3/release-provenance.json)
        cp "$UPGRADE_TEST_PROVENANCE" "$output" ;;
      https://repo.hex.pm/tarballs/*-10.0.3.tar) cp "$UPGRADE_TEST_TAR" "$output" ;;
      *) exit 91 ;;
    esac
    printf 200
    """)

    executable!(Path.join(bin, "git"), """
    #!/bin/sh
    printf '%s\n' "$*" >> "$UPGRADE_TEST_COMMANDS"
    case "$*" in
      'remote get-url origin'|'status --porcelain') exec "$UPGRADE_TEST_GIT" "$@" ;;
      *) exit 92 ;;
    esac
    """)

    for command <- ~w(mix gh) do
      executable!(Path.join(bin, command), """
      #!/bin/sh
      printf '%s\n' '#{command}' >> "$UPGRADE_TEST_COMMANDS"
      exit 93
      """)
    end

    %{
      ui: ui,
      git: git,
      lock: lock,
      metadata: metadata,
      metadata_path: metadata_path,
      evidence: evidence,
      commands: Path.join(tmp_dir, "commands"),
      env: [
        {"PATH", bin <> ":" <> System.get_env("PATH")},
        {"UPGRADE_TEST_PATH", bin <> ":" <> System.get_env("PATH")},
        {"UPGRADE_TEST_SCRIPT", Path.join(__DIR__, "upgrade-ui.exs")},
        {"UPGRADE_TEST_GIT", git},
        {"UPGRADE_TEST_PROVENANCE", provenance},
        {"UPGRADE_TEST_TAR", tar},
        {"UPGRADE_TEST_COMMANDS", Path.join(tmp_dir, "commands")}
      ]
    }
  end

  test "push retries reuse an adopted main with no branch or PR after deletion", ctx do
    before = snapshot(ctx)

    for _ <- 1..2 do
      {output, status} = run(ctx)
      assert status == 0, output
      assert output =~ "UI already pins verified toolchain #{@version}; no upgrade needed"
      assert snapshot(ctx) == before
    end

    assert File.read!(ctx.commands) ==
             String.duplicate("remote get-url origin\nstatus --porcelain\n", 2)
  end

  test "already-pinned main rejects incomplete, stale or non-Hex lock cohorts", ctx do
    for lock <- [
          Map.delete(ctx.lock, :duskmoon_npm),
          Map.put(
            ctx.lock,
            :duskmoon_oxc,
            {:hex, :duskmoon_oxc, "9.16.16", "c", [], [], "hexpm", "o"}
          ),
          Map.put(ctx.lock, :duskmoon_npm, {:git, "https://example.com/toolchain", "sha", []}),
          Map.put(
            ctx.lock,
            :duskmoon_npm,
            {:hex, :duskmoon_npm, @version, "c", [], [], "other", "o"}
          ),
          Map.put(
            ctx.lock,
            :duskmoon_npm,
            {:hex, :unrelated, @version, "c", [], [], "hexpm", "o"}
          )
        ] do
      File.write!(Path.join(ctx.ui, "mix.lock"), inspect(lock) <> "\n")
      commit!(ctx.git, ctx.ui)
      before = snapshot(ctx)
      {output, status} = run(ctx)
      assert status != 0
      assert output =~ "actual lock cohort mismatch"
      assert snapshot(ctx) == before
    end

    assert File.read!(ctx.commands) ==
             String.duplicate("remote get-url origin\nstatus --porcelain\n", 5)
  end

  test "already-pinned main rejects conflicting adoption provenance before mutation", ctx do
    File.write!(
      ctx.metadata_path,
      JSON.encode!(Map.put(ctx.metadata, "source_sha", String.duplicate("b", 40)))
    )

    commit!(ctx.git, ctx.ui)
    before = snapshot(ctx)
    {output, status} = run(ctx)
    assert status != 0
    assert output =~ "immutable output conflict"
    assert snapshot(ctx) == before
    assert File.read!(ctx.commands) == "remote get-url origin\nstatus --porcelain\n"
  end

  defp run(ctx) do
    System.cmd(
      System.find_executable("elixir"),
      [
        "-e",
        "System.put_env(\"PATH\", System.fetch_env!(\"UPGRADE_TEST_PATH\")); Code.require_file(System.fetch_env!(\"UPGRADE_TEST_SCRIPT\"))",
        "--",
        "--push",
        @version,
        @sha,
        ctx.ui,
        ctx.evidence
      ],
      env: ctx.env,
      stderr_to_stdout: true
    )
  end

  defp snapshot(ctx) do
    {
      git!(ctx.git, ctx.ui, ["show-ref"]),
      git!(ctx.git, ctx.ui, ["status", "--porcelain"]),
      for(
        path <- Path.wildcard(Path.join(ctx.ui, "**/*")),
        File.regular?(path),
        do: {Path.relative_to(path, ctx.ui), File.read!(path)}
      )
    }
  end

  defp commit!(git, ui) do
    git!(git, ui, ["add", "."])

    git!(git, ui, [
      "-c",
      "user.name=Retry Test",
      "-c",
      "user.email=retry@example.test",
      "commit",
      "-m",
      "fixture"
    ])
  end

  defp git!(git, ui, args), do: ReleaseSupport.cmd!(git, args, cd: ui)

  defp executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
