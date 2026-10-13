Code.require_file("lib/package_stage.exs", __DIR__)

{opts, rest, invalid} =
  OptionParser.parse(System.argv(), strict: [stage: :string, mode: :string, keep: :boolean])

if rest != [] or invalid != [],
  do:
    raise(
      "Usage: elixir scripts/package-consumer-smoke.exs --stage ABS_PATH --mode source|precompiled"
    )

stage = opts |> Keyword.fetch!(:stage) |> Path.expand()
mode = Keyword.get(opts, :mode, "precompiled")
if mode not in ["source", "precompiled"], do: raise("Invalid native mode #{mode}")
root = Path.expand("..", __DIR__)

if stage == root or String.starts_with?(stage, root <> "/"),
  do: raise("Consumer must use an external staging directory")

manifest = stage |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()
apps = DuskmoonToolchain.PackageStage.apps()

if Enum.sort(Enum.map(manifest["packages"], & &1["name"])) !=
     Enum.sort(Enum.map(apps, &to_string/1)),
   do: raise("Incomplete package cohort")

consumer = Path.join(System.tmp_dir!(), "duskmoon-consumer-#{System.unique_integer([:positive])}")
File.mkdir_p!(consumer)

deps =
  Enum.map(apps, fn app -> {app, [path: Path.join(stage, to_string(app)), override: true]} end)

# Match the source umbrella's explicit ExDoc override: Zigler's documentation
# helper pins 0.39.1 while this package cohort uses ~> 0.40. This applies only
# to candidate source consumers; registry package manifests contain no overrides.
deps =
  if mode == "source" do
    [
      {:zigler, "~> 0.16.0", runtime: false},
      {:rustler, "~> 0.38", runtime: false},
      {:ex_doc, "~> 0.40", runtime: false, override: true}
    ] ++ deps
  else
    deps
  end

source = """
defmodule IsolatedConsumer.MixProject do
  use Mix.Project
  def project, do: [app: :isolated_consumer, version: "0.0.0", elixir: ">= 1.18.0", deps: #{inspect(deps, limit: :infinity)}]
  def application, do: [extra_applications: [:logger]]
end
"""

File.write!(Path.join(consumer, "mix.exs"), source)

check = """
{:ok, _} = OXC.parse("export const answer = 42;", "entry.js")
{:ok, _} = OXC.select("import value from 'value';", "entry.js", :import_specifiers)
{:ok, _} = OXC.Format.run("const answer=42;", "entry.js")
{:ok, _} = OXC.Lint.run("const answer=42;", "entry.js")
{:ok, runtime} = QuickBEAM.start()
{:ok, 42} = QuickBEAM.eval(runtime, "21 * 2")
QuickBEAM.stop(runtime)
{:ok, _} = Vize.parse_sfc("<template><div>candidate</div></template>")
[_ | _] = Oxide.extract(~s(<div class="flex">), "html")
IO.puts("Isolated staged toolchain native consumer passed")
"""

File.write!(Path.join(consumer, "smoke.exs"), check)

try do
  for args <- [["deps.get"], ["compile", "--warnings-as-errors"], ["run", "smoke.exs"]] do
    {output, code} =
      System.cmd("mix", args,
        cd: consumer,
        stderr_to_stdout: true,
        env: [
          {"DUSKMOON_NATIVE_MODE", mode},
          {"MIX_BUILD_PATH", Path.join(consumer, "_build")},
          {"MIX_DEPS_PATH", Path.join(consumer, "deps")},
          {"MIX_ENV", "prod"}
        ]
      )

    IO.write(output)

    if code != 0,
      do:
        raise(
          "Isolated consumer failed mix #{Enum.join(args, " ")} (#{code}); retained at #{consumer}"
        )
  end

  unless opts[:keep], do: File.rm_rf!(consumer)
rescue
  error ->
    IO.puts(:stderr, "Consumer state retained at #{consumer}")
    reraise error, __STACKTRACE__
end
