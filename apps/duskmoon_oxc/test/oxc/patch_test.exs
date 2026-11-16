defmodule OXC.PatchTest do
  use ExUnit.Case, async: true

  test "applies non-overlapping patches regardless of input order" do
    patches = [%{start: 6, end: 8, change: "Z"}, %{start: 0, end: 2, change: "X"}]

    assert OXC.patch_string("abcdefgh", patches) == "XcdefZ"
  end

  test "applies an insertion before a replacement that starts at the same offset" do
    insertion = %{start: 2, end: 2, change: "I"}
    replacement = %{start: 2, end: 4, change: "R"}

    assert OXC.patch_string("abcdefgh", [insertion, replacement]) == "abIRefgh"
    assert OXC.patch_string("abcdefgh", [replacement, insertion]) == "abIRefgh"
  end

  test "applies adjacent patches" do
    patches = [%{start: 2, end: 4, change: "X"}, %{start: 4, end: 6, change: "Y"}]

    assert OXC.patch_string("abcdefgh", patches) == "abXYgh"
  end

  test "drops duplicate patches for the same range" do
    patches = [%{start: 2, end: 4, change: "X"}, %{start: 2, end: 4, change: "Y"}]

    assert OXC.patch_string("abcdefgh", patches) == "abXefgh"
  end

  test "raises on nested patches instead of duplicating replaced text" do
    patches = [%{start: 0, end: 6, change: "X"}, %{start: 2, end: 4, change: "Y"}]

    assert_raise ArgumentError, ~r/overlap/, fn -> OXC.patch_string("abcdefgh", patches) end
  end

  test "raises on different replacements that start at the same offset" do
    patches = [%{start: 2, end: 6, change: "X"}, %{start: 2, end: 4, change: "Y"}]

    assert_raise ArgumentError, ~r/overlap/, fn -> OXC.patch_string("abcdefgh", patches) end
  end

  test "raises on an insertion inside a replaced range" do
    patches = [%{start: 2, end: 6, change: "X"}, %{start: 4, end: 4, change: "I"}]

    assert_raise ArgumentError, ~r/overlap/, fn -> OXC.patch_string("abcdefgh", patches) end
  end

  test "raises on a patch that ends before it starts" do
    assert_raise ArgumentError, ~r/ends before it starts/, fn ->
      OXC.patch_string("abcdefgh", [%{start: 4, end: 2, change: "X"}])
    end
  end
end
