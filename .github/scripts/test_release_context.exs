Code.require_file("release_support.exs", __DIR__)
Code.require_file("workflow_checks.exs", __DIR__)
repository = System.fetch_env!("GITHUB_REPOSITORY")
server = System.fetch_env!("GITHUB_SERVER_URL")
version = System.get_env("VERSION", "")

request =
  if version != "" do
    %{
      "version" => version,
      "source_sha" => System.fetch_env!("SOURCE_SHA"),
      "release_run" =>
        "#{server}/#{repository}/actions/runs/#{System.fetch_env!("GITHUB_RUN_ID")}"
    }
  else
    event = System.fetch_env!("GITHUB_EVENT_PATH") |> File.read!() |> JSON.decode!()
    run = Map.fetch!(event, "workflow_run")
    run_id = Map.fetch!(run, "id")

    artifacts =
      ReleaseSupport.cmd!("gh", [
        "api",
        "repos/#{repository}/actions/runs/#{run_id}/artifacts?per_page=100",
        "--paginate",
        "--slurp"
      ])
      |> JSON.decode!()
      |> Enum.flat_map(&Map.fetch!(&1, "artifacts"))

    if Enum.any?(artifacts, &(&1["name"] == "release-request" and &1["expired"] == false)) do
      output = Path.join(System.fetch_env!("RUNNER_TEMP"), "release-request")

      ReleaseSupport.cmd!("gh", [
        "run",
        "download",
        to_string(run_id),
        "--repo",
        repository,
        "--name",
        "release-request",
        "--dir",
        output
      ])

      request = output |> Path.join("release-request.json") |> File.read!() |> JSON.decode!()
      WorkflowChecks.published_request!(run, request, repository)
      Map.put(request, "release_run", "#{server}/#{repository}/actions/runs/#{run_id}")
    else
      # Verification-only dispatches already call this test workflow explicitly.
      IO.puts("No new publication request; published-release tests were not scheduled")
      nil
    end
  end

if request do
  version = ReleaseSupport.stable!(request["version"])
  sha = ReleaseSupport.sha!(request["source_sha"])

  File.write!(
    System.fetch_env!("GITHUB_OUTPUT"),
    "version=#{version}\nsource_sha=#{sha}\n" <>
      "current_cohort=#{ReleaseSupport.cohort(version) == ReleaseSupport.cohort()}\n" <>
      "release_run=#{request["release_run"]}\n",
    [:append]
  )
end
