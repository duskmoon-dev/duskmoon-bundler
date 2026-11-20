%{
  configs: [
    %{
      name: "default",
      checks: %{
        disabled: [
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.UnlessWithElse, []}
        ]
      }
    }
  ]
}
