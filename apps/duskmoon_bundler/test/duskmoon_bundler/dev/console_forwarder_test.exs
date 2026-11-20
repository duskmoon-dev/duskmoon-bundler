defmodule DuskmoonBundler.Dev.ConsoleForwarderTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias DuskmoonBundler.Dev.ConsoleForwarder

  test "injects forwarding preamble" do
    code = ConsoleForwarder.inject("console.log('ok')")
    assert code =~ "__duskmoon_bundlerConsoleForwarderInstalled"
    assert code =~ "console.log('ok')"
  end

  test "logs browser payloads" do
    log =
      capture_log(fn ->
        ConsoleForwarder.log(%{
          "level" => "error",
          "source" => "/assets/app.js",
          "args" => ["boom", %{"code" => 500}]
        })
      end)

    assert log =~ "[DuskmoonBundler][browser][/assets/app.js] boom %{\"code\" => 500}"
  end
end
