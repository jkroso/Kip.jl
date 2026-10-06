# Loads its plugin only when asked, from inside a function, as Centient loads agent.jl
using Kip
load_plugin() = include(joinpath(@__DIR__, "lazyplugins", "plug.jl"))
println("host started")
if "--plugin" in ARGS
  load_plugin()
  println(Base.invokelatest(() -> plugin_value()))
end
