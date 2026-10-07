# Reads a data file beside it and includes a file by a relative path, after
# moving into its own folder, as Centient's compile.jl does
using Kip
cd(@__DIR__)
const greeting = read(joinpath(@__DIR__, "data", "greeting.txt"), String)
include("parts/part.jl")
println(strip(greeting), ", ", part_name(), ", ", isfile("withdata.jl"))
