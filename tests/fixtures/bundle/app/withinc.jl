# Includes a file by a path written in the source, as Centient's main.jl does
using Kip
include(joinpath(@__DIR__, "parts", "part.jl"))
println(part_name())
