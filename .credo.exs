%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "credo_checks/"],
        excluded: []
      },
      # Only Fae's custom checks run in the gate. Adopting Credo's full
      # default ruleset is a separate, later decision.
      checks: [
        {Fae.Credo.Check.UnlocalizedDateTime, []}
      ]
    }
  ]
}
