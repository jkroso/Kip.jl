using Test

# A program that was built with KIP_FROZEN, like an app, has each file's module
# in its image. When it later compiles a cache of a package, the cache names
# every one of those modules, and Julia loads the cache only if it finds each
# of them by that name.
@testset "the modules of files that Kip includes" begin
  kip_root = dirname(@__DIR__)
  top = joinpath(@__DIR__, "fixtures", "frozen", "top.jl")
  script = """
    pushfirst!(LOAD_PATH, $(repr(kip_root)))
    using Kip
    m = Kip.require($(repr(top)))
    println(Base.invokelatest(m.both))
    for x in values(Kip.modules)
      id = Base.PkgId(x)
      println(nameof(x), " ", parentmodule(x) === x, " ", Base.root_module(id) === x, " ",
              Base.maybe_loaded_precompile(id, Base.module_build_id(x)) === x)
    end
    """
  julia = joinpath(Sys.BINDIR, Base.julia_exename())
  lines = split(read(addenv(`$julia --startup-file=no -e $script`, "KIP_FROZEN" => "1"), String), '\n', keepempty=false)
  @test lines[1] == "3"
  names = String.(first.(split.(lines[2:end])))
  @testset "two files of one name get names of their own" begin
    @test length(names) == 3 && allunique(names)
    @test any(endswith("/sub/part"), names)
  end
  @testset "each is a root module that Julia finds by its name" begin
    @test all(endswith(" true true true"), lines[2:end])
  end
end
