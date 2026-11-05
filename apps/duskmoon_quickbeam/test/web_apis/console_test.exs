defmodule QuickBEAM.WebAPIs.ConsoleTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  setup_all do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
    :ok
  end

  test "console.log routes to Logger" do
    {:ok, rt} = QuickBEAM.start()

    log =
      capture_log(fn ->
        QuickBEAM.eval(rt, ~s[console.log("hello from JS")])
        Process.sleep(50)
      end)

    assert log =~ "hello from JS"
    QuickBEAM.stop(rt)
  end

  test "console.warn routes to Logger warning" do
    {:ok, rt} = QuickBEAM.start()

    log =
      capture_log([level: :warning], fn ->
        QuickBEAM.eval(rt, ~s[console.warn("JS warning")])
        Process.sleep(50)
      end)

    assert log =~ "JS warning"
    QuickBEAM.stop(rt)
  end

  test "console.error routes to Logger error" do
    {:ok, rt} = QuickBEAM.start()

    log =
      capture_log([level: :error], fn ->
        QuickBEAM.eval(rt, ~s[console.error("JS error")])
        Process.sleep(50)
      end)

    assert log =~ "JS error"
    QuickBEAM.stop(rt)
  end

  test "console.log with multiple arguments" do
    {:ok, rt} = QuickBEAM.start()

    log =
      capture_log(fn ->
        QuickBEAM.eval(rt, ~s[console.log("a", "b", "c")])
        Process.sleep(50)
      end)

    assert log =~ "a b c"
    QuickBEAM.stop(rt)
  end
end
