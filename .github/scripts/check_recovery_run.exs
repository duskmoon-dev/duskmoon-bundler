Code.require_file("release_support.exs", __DIR__)
Code.require_file("workflow_checks.exs", __DIR__)
[sha, run_id] = System.argv()
ReleaseSupport.checked_head!(sha)
unless run_id =~ ~r/^\d+$/, do: raise("an original release run ID is required")
repository = "duskmoon-dev/duskmoon-bundler"

ReleaseSupport.cmd!("gh", ["api", "repos/#{repository}/compare/#{sha}...main"])
|> JSON.decode!()
|> WorkflowChecks.on_main!(sha)

endpoint = "repos/#{repository}/actions/runs/#{run_id}"
run = ReleaseSupport.cmd!("gh", ["api", endpoint]) |> JSON.decode!()

jobs =
  ReleaseSupport.cmd!("gh", [
    "api",
    "#{endpoint}/jobs?filter=all&per_page=100",
    "--paginate",
    "--slurp"
  ])
  |> JSON.decode!()
  |> Enum.flat_map(&Map.fetch!(&1, "jobs"))
  |> WorkflowChecks.latest_jobs()

# Retry runs that reused the complete public native cohort skip every native job;
# their validate job uploads `native-reused` only after verifying all 47 digests.
reused_native =
  ReleaseSupport.cmd!("gh", [
    "api",
    "#{endpoint}/artifacts?per_page=100",
    "--paginate",
    "--slurp"
  ])
  |> JSON.decode!()
  |> Enum.flat_map(&Map.fetch!(&1, "artifacts"))
  |> Enum.any?(&(&1["name"] == "native-reused"))

ReleaseSupport.recovery_run!(run, jobs, sha, reused_native: reused_native)

IO.puts("Original source, 47 native artifacts and staging gates verified for run #{run_id}")
