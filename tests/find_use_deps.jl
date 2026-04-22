using Test
pushfirst!(LOAD_PATH, joinpath(@__DIR__, ".."))
using Kip

# Helper: names of deps returned by find_use_deps.
depnames(src::String, base::String=pwd()) =
  [n for (_, n) in Kip.find_use_deps(src, base)]

@testset "find_use_deps" begin
  @testset "plain @use returns the main dep" begin
    src = """@use "github.com/jkroso/Prospects.jl" @def"""
    @test "Prospects" in depnames(src)
  end

  @testset "single-line bracket form returns BOTH main and bracketed subdep" begin
    # Regression: the multi-line opener regex used to greedily match this
    # form, setting `use_prefix` and skipping the line entirely — dropping
    # both the main `Units` dep and the bracketed `Money` subdep.
    src = """@use "github.com/jkroso/Units.jl" ["Money" Money AUD] Unit Dimension"""
    names = depnames(src)
    @test "Units" in names
    @test "Money" in names
  end

  @testset "single-line bracket form with bracket NOT adjacent to quote" begin
    src = """@use "github.com/jkroso/Prospects.jl" @def @property ["Enum" @Enum]"""
    names = depnames(src)
    @test "Prospects" in names
    @test "Enum" in names
  end

  @testset "multi-line bracket block still parses" begin
    src = """
    @use "github.com/jkroso/Units.jl" [
      "Money" Money AUD
      "Colloquial" Piece
    ]
    """
    names = depnames(src)
    @test "Money" in names
    @test "Colloquial" in names
  end

  @testset "slash-path subpath form returns only the subpath dep" begin
    src = """@use "github.com/jkroso/Units.jl/Colloquial" Piece Counting"""
    @test "Colloquial" in depnames(src)
  end
end
