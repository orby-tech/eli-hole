%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/", "config/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: %{
        enabled: [
          {Credo.Check.Design.AliasUsage,
           excluded_namespaces: ~w[Phoenix Ecto], if_nested_deeper_than: 2},
          {Credo.Check.Readability.AliasOrder, false}
        ]
      }
    }
  ]
}
