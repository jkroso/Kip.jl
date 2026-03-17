using Test
# Load Kip from the project source
pushfirst!(LOAD_PATH, joinpath(@__DIR__, ".."))
using Kip

const fixtures = joinpath(@__DIR__, "fixtures")

@testset "Kip.compile" begin
  @testset "returns the input path (main file not compiled)" begin
    entry = joinpath(fixtures, "has_dep.jl")
    result = Kip.compile(entry)
    @test result == realpath(entry)
  end

  @testset "consistent across runs" begin
    entry = joinpath(fixtures, "has_dep.jl")
    @test Kip.compile(entry) == Kip.compile(entry)
  end

  @testset "deps are compiled into PWD-based output dir" begin
    entry = joinpath(fixtures, "has_dep.jl")
    Kip.compile(entry)
    pwd_hash = bytes2hex(Kip.SHA.sha256(Vector{UInt8}(Kip.initial_pwd)))[1:16]
    output_dir = joinpath(Kip.cache, pwd_hash)
    subdirs = filter(isdir, map(d -> joinpath(output_dir, d), readdir(output_dir)))
    @test !isempty(subdirs)
    @test any(subdirs) do d
      isdir(joinpath(d, "src")) && isfile(joinpath(d, "Project.toml"))
    end
  end

  @testset "main file is not in output dir" begin
    entry = joinpath(fixtures, "has_dep.jl")
    Kip.compile(entry)
    pwd_hash = bytes2hex(Kip.SHA.sha256(Vector{UInt8}(Kip.initial_pwd)))[1:16]
    output_dir = joinpath(Kip.cache, pwd_hash)
    entry_hash = Kip.source_hash(read(realpath(entry), String))
    @test !isdir(joinpath(output_dir, entry_hash))
  end

  @testset "load_module works without explicit name" begin
    path, _ = Kip.complete(joinpath(fixtures, "simple.jl"))
    mod = Kip.load_module(realpath(path))
    @test isdefined(mod, :greet)
  end

  @testset "@use PkgName installs and loads stdlib packages" begin
    # Dates is a stdlib, so no download needed
    mod = Kip.load_module(realpath(joinpath(fixtures, "uses_pkg.jl")))
    @test isdefined(mod, :today_str)
    @test mod.today_str() isa String
  end

  @testset "@use PkgName installs and loads 3rd party packages" begin
    mod = Kip.load_module(realpath(joinpath(fixtures, "uses_3rd_party.jl")))
    @test isdefined(mod, :to_json)
    @test mod.to_json(Dict("a" => 1)) isa String
  end

  @testset "installed() checks initial_pwd Project.toml" begin
    # stdlib packages are always installed
    @test Kip.installed("Dates")
    # nonexistent packages are not
    @test !Kip.installed("NonExistentPkg_xyz_12345")
  end
end
