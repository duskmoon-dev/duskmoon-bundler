root = Path.expand("..", __DIR__)
toolchain = File.read!(Path.join(root, "rust-toolchain.toml"))
[_, version] = Regex.run(~r/^channel = "([^"]+)"$/m, toolchain)
minimum = version |> String.split(".") |> Enum.take(2) |> Enum.join(".")

{compiler, status} = System.cmd("rustc", ["--version"])

unless status == 0 and String.starts_with?(compiler, "rustc #{version} "),
  do: raise("Expected Rust #{version}, got #{String.trim(compiler)}")

for manifest <- Path.wildcard(Path.join(root, "apps/duskmoon_*/native/*/Cargo.toml")) do
  source = File.read!(manifest)
  unless source =~ ~s(rust-version = "#{minimum}"), do: raise("Rust version differs: #{manifest}")
end

for relative <- [
      ".github/actions/setup-toolchain/action.yml",
      ".github/workflows/native-prebuild.yml",
      ".github/workflows/ui-compatibility.yml"
    ] do
  source = File.read!(Path.join(root, relative))

  unless Regex.match?(~r/toolchain:\s*['"]?#{Regex.escape(version)}['"]?\s*$/m, source),
    do: raise("Rust toolchain pin differs: #{relative}")
end

IO.puts("Rust #{version} pins match native crates and CI/release workflows")
