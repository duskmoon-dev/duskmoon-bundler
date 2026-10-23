Code.require_file("release_support.exs", __DIR__)
Code.require_file("workflow_checks.exs", __DIR__)
[sha, ui_sha] = System.argv()
ReleaseSupport.checked_head!(sha)
ReleaseSupport.sha!(ui_sha)
repository = System.fetch_env!("GITHUB_REPOSITORY")

for {workflow, required} <- [
      {"ci.yml", ["build"]},
      {"test.yml", ["test", "candidate-ui / #{ui_sha}"]}
    ] do
  runs =
    ReleaseSupport.cmd!("gh", [
      "api",
      "repos/#{repository}/actions/workflows/#{workflow}/runs?head_sha=#{sha}&per_page=100",
      "--paginate",
      "--slurp"
    ])
    |> JSON.decode!()
    |> Enum.flat_map(&Map.fetch!(&1, "workflow_runs"))

  run = WorkflowChecks.successful_run!(runs, sha, workflow)

  jobs =
    ReleaseSupport.cmd!("gh", [
      "api",
      "repos/#{repository}/actions/runs/#{run["id"]}/jobs?filter=all&per_page=100",
      "--paginate",
      "--slurp"
    ])
    |> JSON.decode!()
    |> Enum.flat_map(&Map.fetch!(&1, "jobs"))
    |> WorkflowChecks.latest_jobs()

  WorkflowChecks.successful_jobs!(jobs, required)
  IO.puts("Verified #{workflow}: #{run["html_url"]}")

  File.write!(
    System.fetch_env!("GITHUB_OUTPUT"),
    "#{Path.rootname(workflow)}_run=#{run["id"]}\n",
    [:append]
  )
end
