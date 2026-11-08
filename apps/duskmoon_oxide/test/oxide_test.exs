defmodule OxideTest do
  use ExUnit.Case, async: true

  test "extracts candidates with their source byte positions" do
    assert [
             %Oxide.Candidate{value: "class", position: 0},
             %Oxide.Candidate{value: "flex", position: 7},
             %Oxide.Candidate{value: "text-red-500", position: 12}
           ] = Oxide.extract(~s(class="flex text-red-500"), "html")
  end

  test "scans Ruby word arrays with angle brackets and custom delimiters incrementally" do
    scanner = Oxide.new()
    content = ~s(%w<flex gap-4>\n%w|block px-2|)
    changed = [%{content: content, extension: "rb"}]

    candidates = Oxide.scan_files(scanner, changed)

    for candidate <- ["flex", "gap-4", "block", "px-2"] do
      assert candidate in candidates
    end

    assert [] = Oxide.scan_files(scanner, changed)
    assert ["grid"] = Oxide.scan_files(scanner, [%{content: "grid flex", extension: "html"}])
  end

  test "rejects changed entries without file or content and keeps the scanner usable" do
    scanner = Oxide.new()

    assert_raise ArgumentError, ~r/either :file or :content/, fn ->
      Oxide.scan_files(scanner, [%{extension: "html"}])
    end

    # Bypass Elixir validation: the NIF must raise instead of panicking while
    # holding (and poisoning) the scanner lock.
    assert_raise ArgumentError, fn ->
      Oxide.Native.scan_files(scanner, [
        %Oxide.Changed{content: "flex", extension: "html"},
        %Oxide.Changed{extension: "html"}
      ])
    end

    assert ["flex"] = Oxide.scan_files(scanner, [%{content: "flex", extension: "html"}])
    assert is_list(Oxide.files(scanner))
  end
end
