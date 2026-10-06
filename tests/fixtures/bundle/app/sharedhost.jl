# Loads its plugins itself, but already uses what they @use
using Kip
@use "../lib/c" cname
for file in sort(readdir(joinpath(@__DIR__, "plugins"), join=true))
  include(file)
end
println(plugin_name())
