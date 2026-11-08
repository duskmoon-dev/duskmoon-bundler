defmodule WorkflowChecks do
  @moduledoc false

  def latest_jobs(jobs) do
    jobs
    |> Enum.group_by(&Map.fetch!(&1, "name"))
    |> Enum.map(fn {_name, attempts} ->
      Enum.max_by(attempts, &{Map.fetch!(&1, "run_attempt"), Map.fetch!(&1, "id")})
    end)
  end

  def successful_run!(runs, sha, workflow) do
    run =
      runs
      |> Enum.filter(fn run ->
        run["head_sha"] == sha and run["path"] == ".github/workflows/#{workflow}" and
          run["event"] in ["push", "workflow_dispatch"] and run["head_branch"] == "main"
      end)
      |> Enum.max_by(& &1["id"], fn ->
        raise("run #{workflow} on main at #{sha} before releasing")
      end)

    unless run["status"] == "completed" and run["conclusion"] == "success",
      do: raise("latest #{workflow} at #{sha} has not passed: #{run["html_url"]}")

    run
  end

  # `compare` is the GitHub compare API response for `SHA...main`: the release
  # source must equal main or be one of its ancestors, never a side branch.
  def on_main!(compare, sha) do
    unless compare["status"] in ["identical", "ahead"] and compare["behind_by"] == 0,
      do: raise("release source #{sha} is not on main")

    sha
  end

  def successful_jobs!(jobs, names) do
    for name <- names do
      unless Enum.any?(jobs, &(&1["name"] == name and &1["conclusion"] == "success")),
        do: raise("required test/build gate did not pass: #{name}")
    end

    :ok
  end

  def published_request!(run, request, repository) do
    unless run["path"] == ".github/workflows/release.yml" and
             run["event"] == "workflow_dispatch" and run["status"] == "completed" and
             run["conclusion"] == "success" and
             get_in(run, ["head_repository", "full_name"]) == repository and
             request["source_sha"] == run["head_sha"],
           do: raise("published tests require a successful release at its exact source SHA")

    request
  end
end
