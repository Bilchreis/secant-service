alias SecantService.PlotDB
alias SecantService.SecNodes.SecNode
require Ash.Query

sec_node =
  SecNode
  |> Ash.Query.filter(uuid == ^"01c166b8-33bf-4ef6-9ff7-81faa6836354")
  |> Ash.read_first!()

mass_spec = Enum.find(sec_node.modules, fn m -> m.name == "mass_spec" end)

Benchee.run(%{
  "mass_spec" => fn -> PlotDB.module_plot(mass_spec) end
})

:eprof.start_profiling([self()])

PlotDB.module_plot(mass_spec)

:eprof.stop_profiling()
:eprof.analyze()
