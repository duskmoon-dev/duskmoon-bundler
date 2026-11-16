defmodule NPMSemverTest do
  use ExUnit.Case, async: true

  # Range fixtures following node-semver's test/fixtures/range-include.js,
  # range-exclude.js and range-parse.js. A third element holds options.
  @ip [include_prerelease: true]
  @loose [loose: true]

  @satisfies [
    {"1.0.0 - 2.0.0", "1.2.3"},
    {"^1.2.3+build", "1.2.3"},
    {"^1.2.3+build", "1.3.0"},
    {"1.2.3-pre+asdf - 2.4.3-pre+asdf", "1.2.3"},
    {"1.2.3pre+asdf - 2.4.3-pre+asdf", "1.2.3", @loose},
    {"1.2.3-pre+asdf - 2.4.3pre+asdf", "1.2.3", @loose},
    {"1.2.3pre+asdf - 2.4.3pre+asdf", "1.2.3", @loose},
    {"1.2.3-pre+asdf - 2.4.3-pre+asdf", "1.2.3-pre.2"},
    {"1.2.3-pre+asdf - 2.4.3-pre+asdf", "2.4.3-alpha"},
    {"1.2.3+asdf - 2.4.3+asdf", "1.2.3"},
    {"1.0.0", "1.0.0"},
    {">=*", "0.2.4"},
    {"", "1.0.0"},
    {"*", "1.2.3"},
    {"*", "v1.2.3", @loose},
    {">=1.0.0", "1.0.0"},
    {">=1.0.0", "1.0.1"},
    {">=1.0.0", "1.1.0"},
    {">1.0.0", "1.0.1"},
    {">1.0.0", "1.1.0"},
    {"<=2.0.0", "2.0.0"},
    {"<=2.0.0", "1.9999.9999"},
    {"<=2.0.0", "0.2.9"},
    {"<2.0.0", "1.9999.9999"},
    {"<2.0.0", "0.2.9"},
    {">= 1.0.0", "1.0.0"},
    {">=  1.0.0", "1.0.1"},
    {">=   1.0.0", "1.1.0"},
    {"> 1.0.0", "1.0.1"},
    {">  1.0.0", "1.1.0"},
    {"<=   2.0.0", "2.0.0"},
    {"<= 2.0.0", "1.9999.9999"},
    {"<=  2.0.0", "0.2.9"},
    {"<    2.0.0", "1.9999.9999"},
    {"<\t2.0.0", "0.2.9"},
    {">=0.1.97", "v0.1.97", @loose},
    {">=0.1.97", "0.1.97"},
    {"0.1.20 || 1.2.4", "1.2.4"},
    {">=0.2.3 || <0.0.1", "0.0.0"},
    {">=0.2.3 || <0.0.1", "0.2.3"},
    {">=0.2.3 || <0.0.1", "0.2.4"},
    {"||", "1.3.4"},
    {"2.x.x", "2.1.3"},
    {"1.2.x", "1.2.3"},
    {"1.2.x || 2.x", "2.1.3"},
    {"1.2.x || 2.x", "1.2.3"},
    {"x", "1.2.3"},
    {"2.*.*", "2.1.3"},
    {"1.2.*", "1.2.3"},
    {"1.2.* || 2.*", "2.1.3"},
    {"1.2.* || 2.*", "1.2.3"},
    {"2", "2.1.2"},
    {"2.3", "2.3.1"},
    {"~0.0.1", "0.0.1"},
    {"~0.0.1", "0.0.2"},
    {"~x", "0.0.9"},
    {"~2", "2.0.9"},
    {"~2.4", "2.4.0"},
    {"~2.4", "2.4.5"},
    {"~>3.2.1", "3.2.2"},
    {"~1", "1.2.3"},
    {"~>1", "1.2.3"},
    {"~> 1", "1.2.3"},
    {"~1.0", "1.0.2"},
    {"~ 1.0", "1.0.2"},
    {"~ 1.0.3", "1.0.12"},
    {"~ 1.0.3alpha", "1.0.12", @loose},
    {">=1", "1.0.0"},
    {">= 1", "1.0.0"},
    {"<1.2", "1.1.1"},
    {"< 1.2", "1.1.1"},
    {"~v0.5.4-pre", "0.5.5"},
    {"~v0.5.4-pre", "0.5.4"},
    {"=0.7.x", "0.7.2"},
    {"<=0.7.x", "0.7.2"},
    {">=0.7.x", "0.7.2"},
    {"<=0.7.x", "0.6.2"},
    {"~1.2.1 >=1.2.3", "1.2.3"},
    {"~1.2.1 =1.2.3", "1.2.3"},
    {"~1.2.1 1.2.3", "1.2.3"},
    {"~1.2.1 >=1.2.3 1.2.3", "1.2.3"},
    {"~1.2.1 1.2.3 >=1.2.3", "1.2.3"},
    {">=1.2.1 1.2.3", "1.2.3"},
    {"1.2.3 >=1.2.1", "1.2.3"},
    {">=1.2.3 >=1.2.1", "1.2.3"},
    {">=1.2.1 >=1.2.3", "1.2.3"},
    {">=1.2", "1.2.8"},
    {"^1.2.3", "1.8.1"},
    {"^0.1.2", "0.1.2"},
    {"^0.1", "0.1.2"},
    {"^0.0.1", "0.0.1"},
    {"^1.2", "1.4.2"},
    {"^1.2 ^1", "1.4.2"},
    {"^1.2.3-alpha", "1.2.3-pre"},
    {"^1.2.0-alpha", "1.2.0-pre"},
    {"^0.0.1-alpha", "0.0.1-beta"},
    {"^0.0.1-alpha", "0.0.1"},
    {"^0.1.1-alpha", "0.1.1-beta"},
    {"^x", "1.2.3"},
    {"x - 1.0.0", "0.9.7"},
    {"x - 1.x", "0.9.7"},
    {"1.0.0 - x", "1.9.7"},
    {"1.x - x", "1.9.7"},
    {"<=7.x", "7.9.9"},
    {"2.x", "2.0.0-pre.0", @ip},
    {"2.x", "2.1.0-pre.0", @ip},
    {"1.1.x", "1.1.0-a", @ip},
    {"1.1.x", "1.1.1-a", @ip},
    {"*", "1.0.0-rc1", @ip},
    {"^1.0.0-0", "1.0.1-rc1", @ip},
    {"^1.0.0-rc2", "1.0.1-rc1", @ip},
    {"^1.0.0", "1.0.1-rc1", @ip},
    {"^1.0.0", "1.1.0-rc1", @ip},
    {"1 - 2", "2.0.0-pre", @ip},
    {"1 - 2", "1.0.0-pre", @ip},
    {"1.0 - 2", "1.0.0-pre", @ip},
    {"=0.7.x", "0.7.0-asdf", @ip},
    {">=0.7.x", "0.7.0-asdf", @ip},
    {"<=0.7.x", "0.7.0-asdf", @ip},
    {">=1.0.0 <=1.1.0", "1.1.0-pre", @ip},
    # Once a component is a wildcard, the components after it are ignored.
    {"1.x.3", "1.9.0"},
    {"~1.x.3", "1.9.0"},
    {"^1.x.3", "1.9.0"},
    {">=1.x.3", "1.0.0"},
    {"<=1.x.3", "1.9.9"},
    {"*.2.3", "7.0.0"},
    {"^*.2.3", "7.0.0"},
    {"1.x.3 - 2.x.9", "2.9.9"}
  ]

  @not_satisfies [
    {"1.0.0 - 2.0.0", "2.2.3"},
    {"1.2.3+asdf - 2.4.3+asdf", "1.2.3-pre.2"},
    {"1.2.3+asdf - 2.4.3+asdf", "2.4.3-alpha"},
    {"^1.2.3+build", "2.0.0"},
    {"^1.2.3+build", "1.2.0"},
    {"^1.2.3", "1.2.3-pre"},
    {"^1.2", "1.2.0-pre"},
    {">1.2", "1.3.0-beta"},
    {"<=1.2.3", "1.2.3-beta"},
    {"^1.2.3", "1.2.3-beta"},
    {"=0.7.x", "0.7.0-asdf"},
    {">=0.7.x", "0.7.0-asdf"},
    {"<=0.7.x", "0.7.0-asdf"},
    {"1", "1.0.0beta", @loose},
    {"<1", "1.0.0beta", @loose},
    {"< 1", "1.0.0beta", @loose},
    {"1.0.0", "1.0.1"},
    {">=1.0.0", "0.0.0"},
    {">=1.0.0", "0.0.1"},
    {">=1.0.0", "0.1.0"},
    {">1.0.0", "0.0.1"},
    {">1.0.0", "0.1.0"},
    {"<=2.0.0", "3.0.0"},
    {"<=2.0.0", "2.9999.9999"},
    {"<=2.0.0", "2.2.9"},
    {"<2.0.0", "2.9999.9999"},
    {"<2.0.0", "2.2.9"},
    {">=0.1.97", "v0.1.93", @loose},
    {">=0.1.97", "0.1.93"},
    {"0.1.20 || 1.2.4", "1.2.3"},
    {">=0.2.3 || <0.0.1", "0.0.3"},
    {">=0.2.3 || <0.0.1", "0.2.2"},
    {"2.x.x", "1.1.3"},
    {"2.x.x", "3.1.3"},
    {"1.2.x", "1.3.3"},
    {"1.2.x || 2.x", "3.1.3"},
    {"1.2.x || 2.x", "1.1.3"},
    {"2.*.*", "1.1.3"},
    {"2.*.*", "3.1.3"},
    {"1.2.*", "1.3.3"},
    {"1.2.* || 2.*", "3.1.3"},
    {"1.2.* || 2.*", "1.1.3"},
    {"2", "1.1.2"},
    {"2.3", "2.4.1"},
    {"~0.0.1", "0.1.0-alpha"},
    {"~0.0.1", "0.1.0"},
    {"~2.4", "2.5.0"},
    {"~2.4", "2.3.9"},
    {"~>3.2.1", "3.3.2"},
    {"~>3.2.1", "3.2.0"},
    {"~1", "0.2.3"},
    {"~>1", "2.2.3"},
    {"~1.0", "1.1.0"},
    {"<1", "1.0.0"},
    {">=1.2", "1.1.1"},
    {"1", "2.0.0beta", @loose},
    {"~v0.5.4-beta", "0.5.4-alpha"},
    {"=0.7.x", "0.8.2"},
    {">=0.7.x", "0.6.2"},
    {"<0.7.x", "0.7.2"},
    {"<1.2.3", "1.2.3-beta"},
    {"=1.2.3", "1.2.3-beta"},
    {">1.2", "1.2.8"},
    {"^0.0.1", "0.0.2-alpha"},
    {"^0.0.1", "0.0.2"},
    {"^1.2.3", "2.0.0-alpha"},
    {"^1.2.3", "1.2.2"},
    {"^1.2", "1.1.9"},
    {"*", "v1.2.3-foo", @loose},
    # Invalid versions never satisfy, and must not raise.
    {"*", "not a version"},
    {">=2", "glorp"},
    {"2.x", "3.0.0-pre.0", @ip},
    {"^1.0.0", "1.0.0-rc1", @ip},
    {"^1.0.0", "2.0.0-rc1", @ip},
    {"^1.2.3-rc2", "2.0.0", @ip},
    {"^1.0.0", "2.0.0-rc1"},
    {"1 - 2", "3.0.0-pre", @ip},
    {"1 - 2", "2.0.0-pre"},
    {"1 - 2", "1.0.0-pre"},
    {"1.0 - 2", "1.0.0-pre"},
    {"1.1.x", "1.0.0-a"},
    {"1.1.x", "1.1.0-a"},
    {"1.1.x", "1.2.0-a"},
    {"1.1.x", "1.2.0-a", @ip},
    {"1.1.x", "1.0.0-a", @ip},
    {"1.x", "1.0.0-a"},
    {"1.x", "1.1.0-a"},
    {"1.x", "1.2.0-a"},
    {"1.x", "0.0.0-a", @ip},
    {"1.x", "2.0.0-a", @ip},
    {">=1.0.0 <1.1.0", "1.1.0"},
    {">=1.0.0 <1.1.0", "1.1.0", @ip},
    {">=1.0.0 <1.1.0", "1.1.0-pre"},
    {">=1.0.0 <1.1.0-pre", "1.1.0-pre"},
    {">X", "1.2.3"},
    {"<x", "0.0.0"},
    {"1.x.3", "2.0.3"},
    {"~1.x.3", "2.0.0"},
    {"^1.x.3", "2.0.0"},
    {">1.x.3", "1.9.9"},
    {"<1.x.3", "1.0.0"},
    {"1.x.3 - 2.x.9", "3.0.0"}
  ]

  @invalid_ranges [
    "blerg",
    "not a range!",
    "latest",
    "1.2.3.4",
    "^1.2.3.4",
    ">=1.2.3 foo",
    "git+https://github.com/foo/bar",
    "npm:other@^1.0.0",
    "file:../local",
    "1.2.3 || nope",
    "^^1.2.3",
    ">>1.2.3",
    "1.2.3-",
    "~1.2.3-",
    # A hyphen is only valid as exactly `A - B`.
    "1.2.3 -",
    "- 1.2.3",
    ">=1.0.0 - 2.0.0",
    "^1.0.0 - 2.0.0",
    "1.0.0 - 2.0.0 - 3.0.0",
    "1.0.0 - 2.0.0 >=1.5.0"
  ]

  for {fixture, index} <- Enum.with_index(@satisfies) do
    {range, version, opts} =
      Tuple.insert_at(fixture, tuple_size(fixture), [])
      |> Tuple.to_list()
      |> Enum.take(3)
      |> List.to_tuple()

    test "satisfies ##{index}: #{inspect(version)} in #{inspect(range)} #{inspect(opts)}" do
      assert NPMSemver.matches?(unquote(version), unquote(range), unquote(opts))
    end
  end

  for {fixture, index} <- Enum.with_index(@not_satisfies) do
    {range, version, opts} =
      Tuple.insert_at(fixture, tuple_size(fixture), [])
      |> Tuple.to_list()
      |> Enum.take(3)
      |> List.to_tuple()

    test "does not satisfy ##{index}: #{inspect(version)} in #{inspect(range)} #{inspect(opts)}" do
      refute NPMSemver.matches?(unquote(version), unquote(range), unquote(opts))
    end
  end

  for range <- @invalid_ranges do
    test "invalid range #{inspect(range)} is rejected without raising" do
      assert :error = NPMSemver.parse_range(unquote(range))
      assert :error = NPMSemver.to_elixir_requirement(unquote(range))
      assert :error = NPMSemver.to_hex_constraint(unquote(range))
      refute NPMSemver.matches?("1.2.3", unquote(range))
      assert NPMSemver.max_satisfying(["1.2.3"], unquote(range)) == nil
    end
  end

  describe "wildcards followed by numbers" do
    for range <- ["~1.x.3", "^1.x.3", "1.x.3", ">1.x.3", "<1.x.3", ">=1.x.3", "<=1.x.3", "=1.x.3"] do
      test "#{range} converts like its wildcard form" do
        wildcard = String.replace(unquote(range), "1.x.3", "1.x")

        assert {:ok, requirement} = NPMSemver.to_elixir_requirement(unquote(range))
        assert {:ok, ^requirement} = NPMSemver.to_elixir_requirement(wildcard)
        assert {:ok, _constraint} = NPMSemver.to_hex_constraint(unquote(range))
      end
    end

    test "a leading wildcard matches everything" do
      assert {:ok, requirement} = NPMSemver.to_elixir_requirement("x.2.3")
      assert {:ok, ^requirement} = NPMSemver.to_elixir_requirement("x")
    end
  end

  describe "requirement conversion" do
    for {range, expected} <- [
          {"^1.2.3", ">= 1.2.3 and < 2.0.0-0"},
          {"^0.2.3", ">= 0.2.3 and < 0.3.0-0"},
          {"^0.0.3", ">= 0.0.3 and < 0.0.4-0"},
          {"^0.0", ">= 0.0.0 and < 0.1.0-0"},
          {"^0", "< 1.0.0-0"},
          {"^1.2", ">= 1.2.0 and < 2.0.0-0"},
          {"~1.2.3", ">= 1.2.3 and < 1.3.0-0"},
          {"~1.2", ">= 1.2.0 and < 1.3.0-0"},
          {"~1", ">= 1.0.0 and < 2.0.0-0"},
          {"1.2", ">= 1.2.0 and < 1.3.0-0"},
          {"1", ">= 1.0.0 and < 2.0.0-0"},
          {">1", ">= 2.0.0"},
          {">1.2", ">= 1.3.0"},
          {"<=1.2", "< 1.3.0-0"},
          {"<1.2", "< 1.2.0-0"},
          {"1.2.3 - 2.3.4", ">= 1.2.3 and <= 2.3.4"},
          {"1.2 - 2.3", ">= 1.2.0 and < 2.4.0-0"},
          {"1.2.3 - 2", ">= 1.2.3 and < 3.0.0-0"},
          {">=1.0.0 <2.0.0 || >=3.0.0", ">= 1.0.0 and < 2.0.0 or >= 3.0.0"}
        ] do
      test "#{inspect(range)} becomes #{inspect(expected)}" do
        assert {:ok, unquote(expected)} = NPMSemver.to_elixir_requirement(unquote(range))
      end
    end
  end

  describe "max_satisfying/3" do
    test "picks the highest satisfying version and skips invalid ones" do
      versions = ["1.2.3", "1.9.0", "garbage", "2.0.0-rc.1", "2.0.0", "1.10.0"]

      assert NPMSemver.max_satisfying(versions, "^1.2.0") == "1.10.0"
      assert NPMSemver.max_satisfying(versions, "*") == "2.0.0"
      assert NPMSemver.max_satisfying(versions, "^2.0.0-rc.0") == "2.0.0"
      assert NPMSemver.max_satisfying(versions, "2.0.0-rc.1") == "2.0.0-rc.1"
      assert NPMSemver.max_satisfying(versions, "^3") == nil
    end
  end
end
