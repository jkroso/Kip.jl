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

@testset "__precompile__(false) in user modules" begin
  @testset "module with __precompile__(false) loads without .ji cache" begin
    path = realpath(joinpath(fixtures, "no_precompile.jl"))
    delete!(Kip.modules, path)  # ensure fresh load
    mod = Kip.load_module(path)
    @test mod isa Module
    @test isdefined(mod, :computed_at_load)
    # Should not have produced a .ji file since precompilation is disabled
    source = read(path, String)
    hash = Kip.source_hash(source)
    name = Kip.valid_identifier(replace(Kip.pkgname(path), r"[^\w]" => "_") * "_" * hash[1:12])
    pkg_id = Base.PkgId(Kip.deterministic_uuid(hash), name)
    cache_dir = Base.compilecache_dir(pkg_id)
    has_ji = isdir(cache_dir) && any(f -> endswith(f, ".ji"), readdir(cache_dir))
    @test !has_ji
  end

  @testset "module with __precompile__(false) reloads fresh each time" begin
    path = realpath(joinpath(fixtures, "no_precompile.jl"))
    delete!(Kip.modules, path)
    mod1 = Kip.load_module(path)
    val1 = mod1.computed_at_load
    delete!(Kip.modules, path)
    mod2 = Kip.load_module(path)
    val2 = mod2.computed_at_load
    # Each load should produce a new random value (not cached)
    @test val1 != val2
  end
end

@testset "__init__() in user modules" begin
  @testset "__init__ is called when module is loaded" begin
    path = realpath(joinpath(fixtures, "has_init.jl"))
    delete!(Kip.modules, path)
    mod = Kip.load_module(path)
    @test mod isa Module
    @test isdefined(mod, :initialized)
    @test mod.initialized[] == true
  end
end

@testset "load_module! identity cache" begin
  @testset "returns the same object (===) on repeated calls" begin
    path = joinpath(fixtures, "simple.jl")
    delete!(Kip._canonical_modules, realpath(path))
    a = Kip.load_module!(path)
    b = Kip.load_module!(path)
    @test a === b
  end

  @testset "normalizes different paths to the same module" begin
    # Use a relative-ish path and the realpath — should get the same Module
    path1 = joinpath(fixtures, "simple.jl")
    path2 = joinpath(fixtures, ".", "simple.jl")
    delete!(Kip._canonical_modules, realpath(path1))
    a = Kip.load_module!(path1)
    b = Kip.load_module!(path2)
    @test a === b
  end

  @testset "survives modules dict being cleared" begin
    path = joinpath(fixtures, "dep.jl")
    rpath = realpath(path)
    delete!(Kip._canonical_modules, rpath)
    delete!(Kip.modules, rpath)
    a = Kip.load_module!(path)
    # Clear the underlying load_module cache — load_module! should still return the same object
    delete!(Kip.modules, rpath)
    b = Kip.load_module!(path)
    @test a === b
  end
end
