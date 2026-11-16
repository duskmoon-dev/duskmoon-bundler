defmodule HexSolver.ConstraintTest do
  # `HexSolver.Constraint` is `@moduledoc false`, but `duskmoon_npm` calls
  # `union/2`, `intersect/2`, `difference/2` and `allows?/2` directly
  # (`NPMSemver.to_hex_constraint/2`, `NPM.Resolver`). The two packages ship as
  # one version cohort; these tests pin the behaviour that contract relies on.
  use ExUnit.Case, async: true

  alias HexSolver.Constraint

  @versions ~w(0.9.0 1.0.0 1.2.3 1.5.0 1.9.9 2.0.0-rc.1 2.0.0 2.5.0 3.0.0 3.1.0)

  defp c(requirement), do: HexSolver.parse_constraint!(requirement)

  defp allowed(constraint) do
    Enum.filter(@versions, &Constraint.allows?(constraint, Version.parse!(&1)))
  end

  describe "allows?/2" do
    test "matches versions inside a range" do
      assert allowed(c(">= 1.0.0 and < 2.0.0-0")) == ~w(1.0.0 1.2.3 1.5.0 1.9.9)
      assert allowed(c("== 1.2.3")) == ~w(1.2.3)
      assert allowed(c(">= 0.0.0")) == @versions
    end

    # Constraints order versions by plain semver precedence, so `< 2.0.0`
    # allows `2.0.0-rc.1`. NPMSemver emits `< 2.0.0-0` bounds for that reason.
    test "prereleases follow semver precedence at range bounds" do
      assert Constraint.allows?(c(">= 1.0.0 and < 2.0.0"), Version.parse!("2.0.0-rc.1"))
      refute Constraint.allows?(c(">= 1.0.0 and < 2.0.0-0"), Version.parse!("2.0.0-rc.1"))
      assert Constraint.allows?(c(">= 1.0.0 and <= 2.0.0-rc.1"), Version.parse!("2.0.0-rc.1"))
    end
  end

  describe "union/2" do
    test "allows versions from either side" do
      union = Constraint.union(c(">= 1.0.0 and < 2.0.0-0"), c(">= 3.0.0 and < 4.0.0-0"))

      assert allowed(union) == ~w(1.0.0 1.2.3 1.5.0 1.9.9 3.0.0 3.1.0)
    end

    test "merges overlapping and adjacent ranges" do
      union = Constraint.union(c(">= 1.0.0 and < 1.5.0"), c(">= 1.5.0 and < 2.0.0-0"))

      assert allowed(union) == allowed(c(">= 1.0.0 and < 2.0.0-0"))
      assert allowed(Constraint.union(c("== 1.2.3"), c("== 2.5.0"))) == ~w(1.2.3 2.5.0)
    end

    test "is commutative and idempotent for the versions it allows" do
      left = c(">= 1.0.0 and < 2.0.0-0")
      right = c(">= 1.5.0 and < 3.0.0-0")

      assert allowed(Constraint.union(left, right)) == allowed(Constraint.union(right, left))
      assert allowed(Constraint.union(left, left)) == allowed(left)
    end
  end

  describe "intersect/2" do
    test "allows only versions allowed by both sides" do
      intersection = Constraint.intersect(c(">= 1.0.0 and < 2.0.0-0"), c(">= 1.5.0"))

      assert allowed(intersection) == ~w(1.5.0 1.9.9)
    end

    test "disjoint ranges intersect to the empty constraint" do
      intersection = Constraint.intersect(c("< 1.0.0"), c(">= 2.0.0"))

      assert Constraint.empty?(intersection)
      assert allowed(intersection) == []
    end

    test "distributes over a union" do
      union = Constraint.union(c(">= 1.0.0 and < 2.0.0-0"), c(">= 3.0.0"))

      assert allowed(Constraint.intersect(union, c(">= 1.5.0 and < 3.1.0"))) ==
               ~w(1.5.0 1.9.9 3.0.0)
    end
  end

  describe "difference/2" do
    test "removes a single excluded version from a range" do
      difference = Constraint.difference(c(">= 1.0.0 and < 2.0.0-0"), c("== 1.5.0"))

      assert allowed(difference) == ~w(1.0.0 1.2.3 1.9.9)
    end

    test "removes a sub-range and leaves disjoint constraints alone" do
      range = c(">= 1.0.0 and < 3.0.0-0")

      assert allowed(Constraint.difference(range, c(">= 1.5.0 and < 2.5.0"))) ==
               ~w(1.0.0 1.2.3 2.5.0)

      assert allowed(Constraint.difference(range, c(">= 3.0.0"))) == allowed(range)
    end

    test "removing everything leaves the empty constraint" do
      range = c(">= 1.0.0 and < 2.0.0-0")

      assert Constraint.empty?(Constraint.difference(range, range))
      assert Constraint.empty?(Constraint.difference(range, c(">= 0.0.0")))
    end
  end

  describe "the npm range bridge" do
    test "a union of comparator sets round-trips through these operations" do
      # ">=1.0.0 <2.0.0 || >=3.0.0" as NPMSemver.to_hex_constraint/2 builds it.
      constraint =
        Constraint.union(
          Constraint.intersect(c(">= 1.0.0"), c("< 2.0.0")),
          c(">= 3.0.0")
        )

      assert allowed(constraint) == ~w(1.0.0 1.2.3 1.5.0 1.9.9 2.0.0-rc.1 3.0.0 3.1.0)

      # NPM.Resolver excludes versions with `difference/2`.
      assert allowed(Constraint.difference(constraint, c("== 3.0.0"))) ==
               ~w(1.0.0 1.2.3 1.5.0 1.9.9 2.0.0-rc.1 3.1.0)
    end
  end
end
