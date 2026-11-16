defmodule Mix.Tasks.Npm.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  defp run_script(dir, scripts, args) do
    File.write!(Path.join(dir, "package.json"), :json.encode(%{"scripts" => scripts}))

    capture_io(fn ->
      File.cd!(dir, fn -> Mix.Tasks.Npm.Run.run(args) end)
    end)
  end

  test "runs every command of a compound script", %{tmp_dir: dir} do
    output = run_script(dir, %{"build" => "true && echo SECOND_RAN"}, ["build"])
    assert output =~ "SECOND_RAN"
  end

  test "supports leading environment assignments", %{tmp_dir: dir} do
    output =
      run_script(dir, %{"t" => "NPM_RUN_TEST_VAR=hello sh -c 'echo got:$NPM_RUN_TEST_VAR'"}, ["t"])

    assert output =~ "got:hello"
  end

  test "propagates the exit status of a failing later command", %{tmp_dir: dir} do
    capture_io(:stderr, fn ->
      assert catch_exit(run_script(dir, %{"t" => "true && sh -c 'exit 3'"}, ["t"])) ==
               {:shutdown, 3}
    end)
  end

  test "keeps an extra argument containing a space as one argument", %{tmp_dir: dir} do
    output = run_script(dir, %{"t" => "printf '[%s]\\n'"}, ["t", "a b", "it's", "$HOME;x"])
    assert output == "[a b]\n[it's]\n[$HOME;x]\n"
  end

  test "prepends node_modules/.bin to PATH", %{tmp_dir: dir} do
    bin = Path.join(dir, "node_modules/.bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "npm-run-test-tool"), "#!/bin/sh\necho TOOL_RAN\n")
    File.chmod!(Path.join(bin, "npm-run-test-tool"), 0o755)

    assert run_script(dir, %{"t" => "npm-run-test-tool"}, ["t"]) =~ "TOOL_RAN"
  end
end
