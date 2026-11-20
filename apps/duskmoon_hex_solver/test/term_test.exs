defmodule HexSolver.TermTest do
  use ExUnit.Case, async: true

  alias HexSolver.{Constraint, PackageRange, Term}

  test "relations preserve all sign combinations and optional dependency behavior" do
    cases = [
      {true, true, "1.0.0", :subset},
      {true, true, "2.0.0", :disjoint},
      {false, true, "1.0.0", :disjoint},
      {false, true, "2.0.0", :overlapping},
      {true, false, "1.0.0", :disjoint},
      {true, false, "2.0.0", :subset},
      {false, false, "1.0.0", :subset},
      {false, false, "2.0.0", :overlapping}
    ]

    for {left_positive, right_positive, version, relation} <- cases,
        left_optional <- [false, true],
        right_optional <- [false, true] do
      left = term("package", "1.0.0", left_positive, left_optional)
      right = term("package", version, right_positive, right_optional)

      assert Term.do_relation(left, right) == relation
      assert Term.relation(left, right, optionals: false) == relation

      expected =
        case {relation, left_optional, right_optional} do
          {:disjoint, true, false} -> :overlapping
          {:disjoint, _, _} -> :disjoint
          {_, true, true} -> :disjoint
          _ -> relation
        end

      assert Term.relation(left, right) == expected
    end
  end

  test "different packages retain sign-sensitive relations and never intersect" do
    for {left_positive, right_positive, expected} <- [
          {true, true, :disjoint},
          {false, true, :overlapping},
          {true, false, :subset},
          {false, false, :overlapping}
        ] do
      left = term("left", "1.0.0", left_positive, false)
      right = term("right", "1.0.0", right_positive, false)

      assert Term.do_relation(left, right) == expected
      assert Term.intersect(left, right) == nil
    end
  end

  test "intersections preserve sign, optional status and included versions" do
    for positive <- [false, true],
        left_optional <- [false, true],
        right_optional <- [false, true] do
      left = term("package", "1.0.0", positive, left_optional)
      right = term("package", "1.0.0", positive, right_optional)
      optional = left_optional and right_optional

      assert %Term{positive: ^positive, optional: ^optional} =
               result = Term.intersect(left, right)

      assert Constraint.allows?(result.package_range.constraint, Version.parse!("1.0.0"))
      refute Constraint.allows?(result.package_range.constraint, Version.parse!("2.0.0"))
    end

    positive = term("package", "1.0.0", true, false)
    negative = term("package", "1.0.0", false, false)
    other = term("package", "2.0.0", false, false)

    assert Term.intersect(positive, negative) == nil
    assert Term.intersect(negative, positive) == nil
    assert %Term{positive: true} = result = Term.intersect(positive, other)
    assert Constraint.allows?(result.package_range.constraint, Version.parse!("1.0.0"))
    assert %Term{positive: false} = result = Term.intersect(negative, other)
    assert Constraint.allows?(result.package_range.constraint, Version.parse!("1.0.0"))
    assert Constraint.allows?(result.package_range.constraint, Version.parse!("2.0.0"))
    refute Constraint.allows?(result.package_range.constraint, Version.parse!("3.0.0"))
  end

  defp term(name, version, positive, optional) do
    %Term{
      package_range: %PackageRange{name: name, repo: "hexpm", constraint: Version.parse!(version)},
      positive: positive,
      optional: optional
    }
  end
end
