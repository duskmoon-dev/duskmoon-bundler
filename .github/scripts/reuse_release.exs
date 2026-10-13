# Read-only retry preparation. Publishing is deliberately absent from this script.
Code.require_file("release_support.exs", __DIR__)
[version, sha, output] = System.argv()
ReleaseSupport.stable!(version)
ReleaseSupport.checked_head!(sha)
output = Path.expand(output)
if File.exists?(output), do: raise("retry asset directory must be absent")
File.mkdir_p!(output)
metadata = Path.join(output, "release-provenance.json")

url =
  "https://github.com/duskmoon-dev/duskmoon-bundler/releases/download/v#{version}/release-provenance.json"

status =
  ReleaseSupport.cmd!("curl", [
    "--location",
    "--silent",
    "--show-error",
    "--output",
    metadata,
    "--write-out",
    "%{http_code}",
    url
  ])

reusable =
  case status do
    "404" ->
      File.rm!(metadata)
      false

    "200" ->
      state = JSON.decode!(File.read!(metadata))
      ReleaseSupport.immutable_action(state["version"], version)
      ReleaseSupport.immutable_action(state["source_sha"], sha)
      ReleaseSupport.immutable_action(state["mix_lock_sha256"], ReleaseSupport.digest("mix.lock"))
      ReleaseSupport.immutable_action(state["bun_lock_sha256"], ReleaseSupport.digest("bun.lock"))

      unless ReleaseSupport.reusable_native?(state),
        do: raise("existing release provenance lacks the complete immutable native cohort")

      for {name, digest} <- state["native_assets"] do
        unless Path.basename(name) == name and String.ends_with?(name, ".tar.gz"),
          do: raise("invalid artifact filename")

        path = Path.join(output, name)

        ReleaseSupport.http!(
          "https://github.com/duskmoon-dev/duskmoon-bundler/releases/download/v#{version}/#{name}",
          path
        )

        ReleaseSupport.immutable_action(ReleaseSupport.digest(path), digest)
      end

      File.rm!(metadata)
      true

    other ->
      raise("public release retry query failed: HTTP #{other}")
  end

IO.puts("Verified native artifact reuse: #{reusable}")

if path = System.get_env("GITHUB_OUTPUT"),
  do: File.write!(path, "reusable=#{reusable}\n", [:append])
