using Test
# Load Kip from the project source
pushfirst!(LOAD_PATH, joinpath(@__DIR__, ".."))
using Kip

const fixtures = joinpath(@__DIR__, "fixtures")

@testset "Kip.compile" begin
  @testset "simple module compiles to .ji" begin
    result = Kip.compile(joinpath(fixtures, "simple.jl"))
    @test endswith(result, ".ji")
    @test isfile(result)
  end

  @testset "module with @use dep compiles to .ji" begin
    result = Kip.compile(joinpath(fixtures, "has_dep.jl"))
    @test endswith(result, ".ji")
    @test isfile(result)
  end

  @testset "dep itself also gets compiled" begin
    # dep.jl should have been compiled as a transitive dep of has_dep.jl
    result = Kip.compile(joinpath(fixtures, "dep.jl"))
    @test endswith(result, ".ji")
    @test isfile(result)
  end

  @testset "recompile returns same .ji (cached)" begin
    result1 = Kip.compile(joinpath(fixtures, "simple.jl"))
    result2 = Kip.compile(joinpath(fixtures, "simple.jl"))
    @test result1 == result2
  end

  @testset "bad module falls back to .jl path" begin
    result = Kip.compile(joinpath(fixtures, "bad_module.jl"))
    @test endswith(result, ".jl")
  end
end
