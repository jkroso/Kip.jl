# Includes a file from inside a function, but calls that function as it loads
load_part() = include(joinpath(@__DIR__, "lazypart.jl"))
load_part()
early_value() = Base.invokelatest(() -> part_value())
