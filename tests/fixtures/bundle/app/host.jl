# Loads each file in its plugins folder itself while it runs, as Caesar does
using Kip
for file in sort(readdir(joinpath(@__DIR__, "plugins"), join=true))
  include(file)
end
println(plugin_name())
