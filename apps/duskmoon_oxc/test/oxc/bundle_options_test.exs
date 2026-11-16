defmodule OXC.BundleOptionsTest do
  use ExUnit.Case, async: true

  alias OXC.Bundle

  @files [{"entry.js", "export const x = 1"}]

  describe "OXC.bundle/2" do
    test "source map results contain exactly the documented keys" do
      assert {:ok, result} = OXC.bundle(@files, entry: "entry.js", format: :esm, sourcemap: true)
      assert result |> Map.keys() |> Enum.sort() == [:code, :sourcemap]
      assert result.code =~ "const x = 1"
      assert %{"version" => 3, "sources" => ["entry.js"]} = Jason.decode!(result.sourcemap)
    end

    test "rejects unknown output formats instead of falling back to IIFE" do
      for format <- [:umd, :es, nil, "umd", 1] do
        assert_raise ArgumentError, ~r/:format/, fn ->
          OXC.bundle(@files, entry: "entry.js", format: format)
        end
      end

      assert {:ok, esm} = OXC.bundle(@files, entry: "entry.js", format: :esm)
      assert esm =~ "export { x }"
      assert {:ok, cjs} = OXC.bundle(@files, entry: "entry.js", format: :cjs)
      assert cjs =~ "exports.x = x"
      assert {:ok, iife} = OXC.bundle(@files, entry: "entry.js")
      assert iife =~ "(function("
    end

    test "rejects invalid define values and JSX runtimes" do
      assert_raise ArgumentError, ~r/:define/, fn ->
        OXC.bundle(@files, entry: "entry.js", define: %{"A" => 1})
      end

      assert_raise ArgumentError, ~r/:jsx/, fn ->
        OXC.bundle(@files, entry: "entry.js", jsx: :preserve)
      end

      assert_raise ArgumentError, ~r/:target/, fn ->
        OXC.bundle(@files, entry: "entry.js", target: 2019)
      end
    end

    test "accepts iodata sources with a binary tail" do
      source = ["export const x = 1;" | "export const y = 2;"]

      assert {:ok, code} = OXC.bundle([{"entry.js", source}], entry: "entry.js", format: :esm)
      assert code =~ "const x = 1"
      assert code =~ "const y = 2"
    end

    test "reports sources that are not iodata" do
      assert {:error, [%{message: message}]} =
               OXC.bundle([{"entry.js", [:not_iodata]}], entry: "entry.js")

      assert message =~ "Invalid iodata"
      assert message =~ "entry.js"
    end

    test "injects the preamble inside the IIFE wrapper and keeps the source map aligned" do
      source = "console.log(ref)"
      opts = [entry: "entry.js", preamble: "const { ref } = Vue;", sourcemap: true]

      assert {:ok, %{code: code, sourcemap: sourcemap}} = OXC.bundle([{"entry.js", source}], opts)

      lines = String.split(code, "\n")
      wrapper = Enum.find_index(lines, &(&1 =~ "(function"))
      preamble = Enum.find_index(lines, &(&1 =~ "const { ref } = Vue;"))
      call = Enum.find_index(lines, &(&1 =~ "console.log(ref)"))
      assert wrapper < preamble and preamble < call

      # The first mapped segment must sit on the generated line holding the call.
      mapped_line =
        sourcemap
        |> Jason.decode!()
        |> Map.fetch!("mappings")
        |> String.split(";")
        |> Enum.find_index(&(&1 != ""))

      assert mapped_line == call
    end

    test "puts the preamble at the top of ESM and CJS output, never inside user functions" do
      source = "export const f = (function () { return ref })()"

      for format <- [:esm, :cjs] do
        assert {:ok, code} =
                 OXC.bundle([{"entry.js", source}],
                   entry: "entry.js",
                   format: format,
                   preamble: "const { ref } = Vue;"
                 )

        {preamble, _} = :binary.match(code, "const { ref } = Vue;")
        {user_function, _} = :binary.match(code, "(function")
        assert preamble < user_function
        assert {:ok, _} = OXC.parse(code, "bundle.js")
      end
    end
  end

  describe "OXC.Bundle" do
    test "new/1 rejects unknown options" do
      assert %Bundle{minify: true, format: :cjs} = Bundle.new(minify: true, format: :cjs)

      assert_raise ArgumentError, ~r/:bogus/, fn -> Bundle.new(bogus: 1) end
      assert_raise ArgumentError, ~r/:fromat/, fn -> Bundle.new(fromat: :esm) end
    end

    test "run/1 rejects invalid option values" do
      bundle = Bundle.new(entries: [{"entry", "entry.js", "export const x = 1"}])

      assert_raise ArgumentError, ~r/:format/, fn ->
        bundle |> Bundle.format(:umd) |> Bundle.run()
      end

      assert_raise ArgumentError, ~r/:define/, fn ->
        bundle |> Bundle.transform(define: %{"A" => 1}) |> Bundle.run()
      end

      assert_raise ArgumentError, ~r/:jsx/, fn ->
        bundle |> Bundle.transform(jsx: :preserve) |> Bundle.run()
      end

      assert_raise ArgumentError, ~r/:target/, fn ->
        bundle |> Bundle.transform(target: 2019) |> Bundle.run()
      end

      assert {:ok, %Bundle.Result{}} = bundle |> Bundle.format("cjs") |> Bundle.run()
    end

    test "run/1 returns atom-keyed errors like OXC.bundle/2" do
      assert {:error, [%{message: "bundle run requires at least one entry"}]} =
               Bundle.run(Bundle.new())

      assert {:error, [%{message: message}]} =
               Bundle.new(entries: [{"entry", "entry.js", "import './missing.js'"}])
               |> Bundle.run()

      assert message =~ "missing.js"
    end

    test "run/1 reports Rolldown warnings" do
      assert {:ok, %Bundle.Result{warnings: warnings}} =
               Bundle.new(entries: [{"entry", "entry.js", "export const x = eval('1')"}])
               |> Bundle.run()

      assert [%{message: message} | _] = warnings
      assert message =~ "eval"
    end

    test "run/1 applies the preamble" do
      assert {:ok, %Bundle.Result{outputs: [%{code: code}]}} =
               Bundle.new(entries: [{"entry", "entry.js", "console.log(ref)"}], format: :iife)
               |> Bundle.output(preamble: "const { ref } = Vue;")
               |> Bundle.run()

      {wrapper, _} = :binary.match(code, "(function")
      {preamble, _} = :binary.match(code, "const { ref } = Vue;")
      {call, _} = :binary.match(code, "console.log(ref)")
      assert wrapper < preamble and preamble < call
    end

    test "run/1 accepts iodata sources with a binary tail" do
      source = ["export const x = 1;" | "export const y = 2;"]

      assert {:ok, %Bundle.Result{outputs: [%{code: code}]}} =
               Bundle.new(entries: [{"entry", "entry.js", source}])
               |> Bundle.file({"other.js", ["export const z = 3;" | ""]})
               |> Bundle.run()

      assert code =~ "const x = 1"
      assert code =~ "const y = 2"
    end
  end
end
