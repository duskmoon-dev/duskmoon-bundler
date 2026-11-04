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
end
