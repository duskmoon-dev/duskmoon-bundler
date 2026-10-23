# Extract the exact publish archives into a disposable consumer cohort.
Code.require_file("release_support.exs", __DIR__)
[stage, output] = Enum.map(System.argv(), &Path.expand/1)
if File.exists?(output), do: raise("consumer package directory must be absent")
state = JSON.decode!(File.read!(Path.join(stage, "release-provenance.json")))
version = ReleaseSupport.stable!(state["version"])
File.mkdir_p!(output)

for app <- ReleaseSupport.cohort() do
  archive = Path.join([stage, app, "#{app}-#{version}.tar"])
  ReleaseSupport.immutable_action(ReleaseSupport.digest(archive), state["package_tarballs"][app])
  package = Path.join(output, app)
  File.mkdir_p!(package)
  :ok = :erl_tar.extract(String.to_charlist(archive), [{:cwd, String.to_charlist(package)}])

  :ok =
    :erl_tar.extract(String.to_charlist(Path.join(package, "contents.tar.gz")), [
      :compressed,
      {:cwd, String.to_charlist(package)}
    ])
end

File.cp!(Path.join(stage, "manifest.json"), Path.join(output, "manifest.json"))
IO.puts("Exact nine-package Hex archive cohort extracted outside publish state")
