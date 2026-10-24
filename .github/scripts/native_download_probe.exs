# Qualify candidate callbacks or exact published packages against public native bytes.
Code.require_file("release_support.exs", __DIR__)

{mode, version} =
  case System.argv() do
    [] -> {:candidate, "10.0.3"}
    ["published", version] -> {:published, ReleaseSupport.stable!(version)}
  end

legacy_vize =
  case System.get_env("DUSKMOON_PROBE_LEGACY_VIZE_GLIBC") do
    value when value in [nil, ""] -> nil
    value -> value
  end

if legacy_vize do
  unless mode == :candidate and version == "10.0.3" and legacy_vize == "2.39" and
           :os.type() == {:unix, :linux} and
           String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "aarch64"),
         do: raise("legacy ABI expectation only applies to published 10.0.3 ARM GNU Vize")
end

root = Path.expand("../..", __DIR__)

temp =
  Path.join(
    System.tmp_dir!(),
    "native-download-#{System.pid()}-#{System.unique_integer([:positive])}"
  )

File.mkdir!(temp)
# Mix computes relative priv links; use the physical path for macOS /var aliases.
temp = File.cd!(temp, &File.cwd!/0)
provenance_path = Path.join(temp, "release-provenance.json")

ReleaseSupport.http!(
  "https://github.com/duskmoon-dev/duskmoon-bundler/releases/download/v#{version}/release-provenance.json",
  provenance_path
)

state = JSON.decode!(File.read!(provenance_path))
^version = state["version"]
apps = ~w(duskmoon_oxc duskmoon_oxide duskmoon_vize duskmoon_quickbeam)

for app <- apps do
  archive = Path.join(temp, "#{app}.tar")
  ReleaseSupport.http!("https://repo.hex.pm/tarballs/#{app}-#{version}.tar", archive)
  ReleaseSupport.immutable_action(ReleaseSupport.digest(archive), state["package_tarballs"][app])
  package = Path.join(temp, app)
  File.mkdir_p!(package)
  :ok = :erl_tar.extract(String.to_charlist(archive), [{:cwd, String.to_charlist(package)}])

  :ok =
    :erl_tar.extract(String.to_charlist(Path.join(package, "contents.tar.gz")), [
      :compressed,
      {:cwd, String.to_charlist(package)}
    ])
end

consumer = Path.join(temp, "consumer")
File.mkdir_p!(consumer)

deps =
  Enum.map(apps, fn app ->
    {String.to_atom(app), [path: Path.join(temp, app), override: true]}
  end) ++
    [
      {:rustler_precompiled, "== 0.10.0", runtime: false},
      {:zigler_precompiled, "== 0.1.6", runtime: false}
    ]

File.write!(Path.join(consumer, "mix.exs"), """
defmodule NativeDownloadConsumer.MixProject do
  use Mix.Project
  def project, do: [app: :native_download_consumer, version: "0.0.0", deps: #{inspect(deps, limit: :infinity)}]
end
""")

bin = Path.join(temp, "bin")
File.mkdir_p!(bin)
compiler_log = Path.join(temp, "compiler.log")

for compiler <- ~w(cargo rustc zig cc gcc clang) do
  path = Path.join(bin, compiler)

  File.write!(
    path,
    "#!/bin/sh\nprintf '%s\\n' \"$0 $*\" >> \"$DUSKMOON_COMPILER_LOG\"\nexit 97\n"
  )

  File.chmod!(path, 0o755)
end

env = [
  {"DUSKMOON_NATIVE_MODE", "precompiled"},
  {"DUSKMOON_BUILD_NATIVE_FROM_SOURCE", nil},
  {"RUSTLER_PRECOMPILED_FORCE_BUILD_ALL", nil},
  {"ZIGLER_PRECOMPILED_FORCE_BUILD_ALL", nil},
  {"OXC_EX_BUILD", nil},
  {"OXIDE_EX_BUILD", nil},
  {"VIZE_EX_BUILD", nil},
  {"QUICKBEAM_BUILD", nil},
  {"MIX_ENV", "prod"},
  {"MIX_HOME", Path.join(temp, "mix-home")},
  {"MIX_ARCHIVES", Path.join(temp, "mix-home/archives")},
  {"MIX_REBAR3", nil},
  {"MIX_BUILD_PATH", Path.join(consumer, "_build")},
  {"MIX_DEPS_PATH", Path.join(consumer, "deps")},
  {"RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH", Path.join(temp, "rust-cache")},
  {"ZIGLER_PRECOMPILED_GLOBAL_CACHE_PATH", Path.join(temp, "zig-cache")},
  {"PATH", bin <> ":" <> System.get_env("PATH")},
  {"DUSKMOON_COMPILER_LOG", compiler_log}
]

run = fn args -> System.cmd("mix", args, cd: consumer, env: env, stderr_to_stdout: true) end

run! = fn args ->
  {output, status} = run.(args)
  IO.write(output)

  if status != 0,
    do:
      raise(
        "native download probe failed mix #{Enum.join(args, " ")} (#{status}); retained at #{temp}"
      )
end

run!.(["--version"])
run!.(["local.hex", "--force"])
run!.(["local.rebar", "--force"])
run!.(["deps.get"])

if mode == :candidate do
  # Capture the published baseline before applying candidate download code.
  {baseline, status} = run.(["compile", "--warnings-as-errors"])
  IO.write(baseline)

  cond do
    status == 0 ->
      IO.puts("Published baseline fits this runner's current response-header budget")

    baseline =~ "header_too_long" and baseline =~ "10240" ->
      IO.puts("Reproduced published download failure at the default 10240-byte header budget")

    true ->
      raise "published baseline failed outside the header regression; retained at #{temp}"
  end

  # Overlay only the candidate URL callback and its six call sites. Keep the
  # published manifests, checksum files and native binaries at their original B.
  for {app, directory, files} <- [
        {"duskmoon_oxc", "oxc", ["native.ex", "format/native.ex", "lint/native.ex"]},
        {"duskmoon_oxide", "oxide", ["native.ex"]},
        {"duskmoon_vize", "vize", ["native.ex"]},
        {"duskmoon_quickbeam", "quickbeam", ["native.ex"]}
      ],
      file <- ["native_url.ex" | files] do
    relative = Path.join(["lib", directory, file])
    File.cp!(Path.join([root, "apps", app, relative]), Path.join([temp, app, relative]))
  end

  File.rm_rf!(Path.join(consumer, "_build"))
  File.rm_rf!(Path.join(temp, "rust-cache"))
  File.rm_rf!(Path.join(temp, "zig-cache"))
end

run!.(["compile", "--warnings-as-errors"])

if legacy_vize do
  # This immutable fixture predates the Ubuntu 22.04 GNU build baseline. Verify
  # its exact known failure explicitly; published-mode consumers have no exception.
  File.write!(Path.join(consumer, "legacy_vize.exs"), "Vize.parse_sfc(\"<template />\")\n")
  {output, status} = run.(["run", "legacy_vize.exs"])
  IO.write(output)

  unless status != 0 and output =~ "GLIBC_2.39" and output =~ "Vize.Native",
    do: raise("immutable Vize ABI baseline changed; retained at #{temp}")

  IO.puts(
    "::warning::Confirmed immutable 10.0.3 ARM Vize requires GLIBC_2.39. " <>
      "All six downloads passed; the five compatible libraries are executed below. " <>
      "New published cohorts must execute all six libraries on this runner."
  )
end

vize_smoke =
  if legacy_vize,
    do: "",
    else: ~s|{:ok, _} = Vize.parse_sfc("<template><div>download</div></template>")|

File.write!(Path.join(consumer, "smoke.exs"), """
{:ok, _} = OXC.parse("export const answer = 42;", "entry.js")
{:ok, _} = OXC.Format.run("const answer=42;", "entry.js")
{:ok, _} = OXC.Lint.run("const answer=42;", "entry.js")
[_ | _] = Oxide.extract(~s(<div class="flex">), "html")
#{vize_smoke}
{:ok, runtime} = QuickBEAM.start()
{:ok, 42} = QuickBEAM.eval(runtime, "21 * 2")
:ok = QuickBEAM.stop(runtime)
IO.puts("#{if legacy_vize, do: "Five compatible", else: "All six"} native libraries loaded and executed")
""")

run!.(["run", "smoke.exs"])
if File.exists?(compiler_log), do: raise("native download invoked a source compiler")
File.rm_rf!(temp)
IO.puts("Cold #{mode} #{version} precompiled consumer passed with no compiler invocation")
