Code.require_file("workflow_checks.exs", __DIR__)
ExUnit.start()

defmodule WorkflowChecksTest do
  use ExUnit.Case, async: true
  @sha String.duplicate("a", 40)

  defp run(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 10,
        "head_sha" => @sha,
        "path" => ".github/workflows/test.yml",
        "event" => "workflow_dispatch",
        "status" => "completed",
        "conclusion" => "success"
      },
      overrides
    )
  end

  test "partial reruns retain successful jobs and use each retried job's final result" do
    retained = %{"id" => 1, "name" => "test", "run_attempt" => 1, "conclusion" => "success"}

    failed = %{
      "id" => 2,
      "name" => "candidate-ui / pinned-sha",
      "run_attempt" => 1,
      "conclusion" => "failure"
    }

    retried = Map.merge(failed, %{"id" => 3, "run_attempt" => 2, "conclusion" => "success"})
    jobs = WorkflowChecks.latest_jobs([retried, retained, failed])
    assert Enum.sort_by(jobs, & &1["id"]) == [retained, retried]
    assert :ok = WorkflowChecks.successful_jobs!(jobs, ["test", "candidate-ui / pinned-sha"])

    regression = Map.merge(retried, %{"id" => 4, "run_attempt" => 3, "conclusion" => "failure"})

    assert_raise RuntimeError, fn ->
      [retained, failed, retried, regression]
      |> WorkflowChecks.latest_jobs()
      |> WorkflowChecks.successful_jobs!(["test", "candidate-ui / pinned-sha"])
    end
  end

  test "release accepts only successful checks for its exact source workflow" do
    assert WorkflowChecks.successful_run!([run()], @sha, "test.yml") == run()

    for overrides <- [
          %{"head_sha" => String.duplicate("b", 40)},
          %{"path" => ".github/workflows/ci.yml"},
          %{"event" => "pull_request"},
          %{"event" => "workflow_run"},
          %{"status" => "in_progress"},
          %{"conclusion" => "failure"}
        ] do
      assert_raise RuntimeError, fn ->
        WorkflowChecks.successful_run!([run(overrides)], @sha, "test.yml")
      end
    end
  end

  test "a newer failure or unfinished run cannot reuse an older success" do
    for overrides <- [%{"conclusion" => "failure"}, %{"status" => "queued"}] do
      assert_raise RuntimeError, fn ->
        WorkflowChecks.successful_run!(
          [run(), run(Map.put(overrides, "id", 11))],
          @sha,
          "test.yml"
        )
      end
    end
  end

  test "UI integration must pass for the requested immutable UI SHA" do
    ui = String.duplicate("b", 40)
    jobs = [%{"name" => "test", "conclusion" => "success"}]

    assert_raise RuntimeError, fn ->
      WorkflowChecks.successful_jobs!(jobs, ["test", "candidate-ui / #{ui}"])
    end

    matching = jobs ++ [%{"name" => "candidate-ui / #{ui}", "conclusion" => "success"}]
    assert :ok = WorkflowChecks.successful_jobs!(matching, ["test", "candidate-ui / #{ui}"])

    for conclusion <- ["failure", "skipped", "cancelled", nil] do
      failed = [%{"name" => "candidate-ui / #{ui}", "conclusion" => conclusion}]

      assert_raise RuntimeError, fn ->
        WorkflowChecks.successful_jobs!(jobs ++ failed, ["test", "candidate-ui / #{ui}"])
      end
    end
  end

  test "post-release tests reject an unrelated run, fork or artifact source" do
    run =
      run(%{
        "path" => ".github/workflows/release.yml",
        "head_repository" => %{"full_name" => "duskmoon-dev/duskmoon-bundler"}
      })

    request = %{"version" => "10.0.3", "source_sha" => @sha}
    repository = "duskmoon-dev/duskmoon-bundler"
    assert WorkflowChecks.published_request!(run, request, repository) == request

    for overrides <- [
          %{"path" => ".github/workflows/test.yml"},
          %{"event" => "pull_request"},
          %{"conclusion" => "failure"},
          %{"status" => "in_progress"},
          %{"head_repository" => %{"full_name" => "other/fork"}},
          %{"head_sha" => String.duplicate("b", 40)}
        ] do
      assert_raise RuntimeError, fn ->
        WorkflowChecks.published_request!(Map.merge(run, overrides), request, repository)
      end
    end
  end
end

defmodule WorkflowCheckCommandsTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @repository "duskmoon-dev/duskmoon-bundler"

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    gh = Path.join(bin, "gh")

    File.write!(gh, """
    #!/bin/sh
    set -eu
    case "$*" in
      *workflows/ci.yml/runs?*) cat "$MOCK_FIXTURES/ci.json" ;;
      *workflows/test.yml/runs?*) cat "$MOCK_FIXTURES/test.json" ;;
      *runs/10/jobs?filter=all*) cat "$MOCK_FIXTURES/ci-jobs.json" ;;
      *runs/20/jobs?filter=all*) cat "$MOCK_FIXTURES/test-jobs.json" ;;
      *artifacts?*) cat "$MOCK_FIXTURES/artifacts.json" ;;
      'run download '*)
        while [ "$#" -gt 0 ]; do
          if [ "$1" = --dir ]; then shift; output=$1; fi
          shift
        done
        mkdir -p "$output"
        cp "$MOCK_FIXTURES/release-request.json" "$output/release-request.json"
        ;;
      *) echo "Unexpected gh request: $*" >&2; exit 1 ;;
    esac
    """)

    File.chmod!(gh, 0o755)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])

    env = [
      {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
      {"MOCK_FIXTURES", dir},
      {"GITHUB_REPOSITORY", @repository},
      {"GITHUB_SERVER_URL", "https://github.com"},
      {"GITHUB_OUTPUT", Path.join(dir, "outputs")},
      {"RUNNER_TEMP", dir}
    ]

    %{sha: String.trim(sha), env: env}
  end

  test "release CLI verifies paginated checks with retained and retried jobs", ctx do
    ui = String.duplicate("b", 40)

    for {workflow, id} <- [{"ci", 10}, {"test", 20}] do
      fixture(ctx, "#{workflow}.json", [
        %{
          "workflow_runs" => [
            %{
              "id" => id,
              "head_sha" => ctx.sha,
              "path" => ".github/workflows/#{workflow}.yml",
              "event" => "workflow_dispatch",
              "status" => "completed",
              "conclusion" => "success"
            }
          ]
        }
      ])
    end

    fixture(ctx, "ci-jobs.json", [%{"jobs" => [job(1, "build", 1, "success")]}])

    fixture(ctx, "test-jobs.json", [
      %{"jobs" => [job(2, "test", 1, "success"), job(3, "candidate-ui / #{ui}", 1, "failure")]},
      %{"jobs" => [job(4, "candidate-ui / #{ui}", 2, "success")]}
    ])

    {output, status} = command("check_workflow_runs.exs", [ctx.sha, ui], ctx.env)
    assert status == 0, output
    assert File.read!(Path.join(ctx.tmp_dir, "outputs")) == "ci_run=10\ntest_run=20\n"

    fixture(ctx, "test-jobs.json", [%{"jobs" => [job(2, "test", 1, "success")]}])
    {output, status} = command("check_workflow_runs.exs", [ctx.sha, ui], ctx.env)
    assert status != 0
    assert output =~ "required test/build gate did not pass: candidate-ui / #{ui}"
  end

  test "post-release CLI resolves the original publication and ignores verification-only runs",
       ctx do
    run = %{
      "id" => 30,
      "path" => ".github/workflows/release.yml",
      "event" => "workflow_dispatch",
      "status" => "completed",
      "conclusion" => "success",
      "head_sha" => ctx.sha,
      "head_repository" => %{"full_name" => @repository}
    }

    fixture(ctx, "event.json", %{"workflow_run" => run})
    fixture(ctx, "release-request.json", %{"version" => "10.0.3", "source_sha" => ctx.sha})

    fixture(ctx, "artifacts.json", [
      %{"artifacts" => [%{"name" => "release-request", "expired" => false}]}
    ])

    env =
      ctx.env ++ [{"GITHUB_EVENT_PATH", Path.join(ctx.tmp_dir, "event.json")}, {"VERSION", ""}]

    {output, status} = command("test_release_context.exs", [], env)
    assert status == 0, output
    outputs = File.read!(Path.join(ctx.tmp_dir, "outputs"))
    assert outputs =~ "version=10.0.3\nsource_sha=#{ctx.sha}\ncurrent_cohort=true\n"
    assert outputs =~ "release_run=https://github.com/#{@repository}/actions/runs/30\n"

    File.rm!(Path.join(ctx.tmp_dir, "outputs"))
    fixture(ctx, "artifacts.json", [%{"artifacts" => []}])
    {output, status} = command("test_release_context.exs", [], env)
    assert status == 0, output
    refute File.exists?(Path.join(ctx.tmp_dir, "outputs"))
  end

  defp job(id, name, attempt, conclusion),
    do: %{"id" => id, "name" => name, "run_attempt" => attempt, "conclusion" => conclusion}

  defp fixture(ctx, name, data),
    do: File.write!(Path.join(ctx.tmp_dir, name), JSON.encode!(data))

  defp command(script, args, env) do
    System.cmd("elixir", [Path.join(__DIR__, script) | args], env: env, stderr_to_stdout: true)
  end
end
