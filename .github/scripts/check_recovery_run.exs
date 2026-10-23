Code.require_file("release_support.exs", __DIR__)
Code.require_file("workflow_checks.exs", __DIR__)
[sha, run_id] = System.argv()
ReleaseSupport.checked_head!(sha)
unless run_id =~ ~r/^\d+$/, do: raise("an original release run ID is required")
endpoint = "repos/duskmoon-dev/duskmoon-bundler/actions/runs/#{run_id}"
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

ReleaseSupport.recovery_run!(run, jobs, sha)

IO.puts(
  "Original source, pinned UI, 47 native builds and staging gates verified for run #{run_id}"
)
