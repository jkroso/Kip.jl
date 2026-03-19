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

  @testset "transitive 3rd party package deps emit Base.require in wrapper" begin
    # Verify that a module using a 3rd party package gets a Base.require line
    # in its wrapper so the compilecache subprocess can find the package
    path = realpath(joinpath(fixtures, "dep_uses_pkg.jl"))
    source = read(path, String)
    hash = Kip.source_hash(source)
    name = Kip.valid_identifier(replace(Kip.pkgname(path), r"[^\w]" => "_") * "_" * hash[1:12])
    pkg_dir = joinpath(Kip.cache, hash)
    # Clean any existing cache so create_cache_package runs fresh
    rm(pkg_dir, recursive=true, force=true)
    Kip.create_cache_package(path, hash, name, source)
    wrapper_path = joinpath(pkg_dir, "src", "$name.jl")
    @test isfile(wrapper_path)
    wrapper = read(wrapper_path, String)
    @test occursin("Base.require(Base.PkgId(Base.UUID(", wrapper)
    @test occursin("JSON3", wrapper)
    # No Manifest.toml should be generated
    @test !isfile(joinpath(pkg_dir, "Manifest.toml"))
  end

  @testset "dep with transitive 3rd party package loads correctly" begin
    # End-to-end test: loading a module whose Kip dep uses a 3rd party package
    path = realpath(joinpath(fixtures, "has_dep_with_pkg.jl"))
    delete!(Kip.modules, path)
    mod = Kip.load_module(path)
    @test isdefined(mod, :show_json)
    @test Base.invokelatest(mod.show_json, Dict("a" => 1)) isa String
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

@testset "__init__() called when precompilation fails" begin
  @testset "__init__ runs on fallback include path" begin
    path = realpath(joinpath(fixtures, "bad_module_with_init.jl"))
    delete!(Kip.modules, path)
    mod = Kip.load_module(path)
    @test mod isa Module
    @test isdefined(mod, :initialized)
    @test mod.initialized[] == true
  end
end

@testset "load_module identity cache" begin
  @testset "returns the same object (===) on repeated calls" begin
    path = joinpath(fixtures, "simple.jl")
    delete!(Kip.modules, realpath(path))
    a = Kip.load_module(path)
    b = Kip.load_module(path)
    @test a === b
  end

  @testset "normalizes different paths to the same module" begin
    path1 = joinpath(fixtures, "simple.jl")
    path2 = joinpath(fixtures, ".", "simple.jl")
    delete!(Kip.modules, realpath(path1))
    a = Kip.load_module(path1)
    b = Kip.load_module(path2)
    @test a === b
  end
end

@testset "recompilation on source change" begin
  @testset "edited module produces new .ji and new values" begin
    # Write v1 of a temp module
    path = joinpath(fixtures, "mutable_mod.jl")
    write(path, "value() = 1\n")
    try
      rpath = realpath(path)
      delete!(Kip.modules, rpath)
      mod1 = Kip.load_module(rpath)
      @test Base.invokelatest(mod1.value) == 1

      # Grab the .ji path for v1
      src1 = read(rpath, String)
      hash1 = Kip.source_hash(src1)
      name1 = Kip.valid_identifier(replace(Kip.pkgname(rpath), r"[^\w]" => "_") * "_" * hash1[1:12])
      pkg_id1 = Base.PkgId(Kip.deterministic_uuid(hash1), name1)
      cache_dir1 = Base.compilecache_dir(pkg_id1)
      @test isdir(cache_dir1)
      @test any(f -> endswith(f, ".ji"), readdir(cache_dir1))

      # Edit the file — new content means new hash, so a fresh compile
      write(path, "value() = 2\n")
      delete!(Kip.modules, rpath)
      mod2 = Kip.load_module(rpath)
      @test Base.invokelatest(mod2.value) == 2
      @test mod2 !== mod1

      # The new version should have its own .ji under a different hash
      src2 = read(rpath, String)
      hash2 = Kip.source_hash(src2)
      @test hash1 != hash2
      name2 = Kip.valid_identifier(replace(Kip.pkgname(rpath), r"[^\w]" => "_") * "_" * hash2[1:12])
      pkg_id2 = Base.PkgId(Kip.deterministic_uuid(hash2), name2)
      cache_dir2 = Base.compilecache_dir(pkg_id2)
      @test isdir(cache_dir2)
      @test any(f -> endswith(f, ".ji"), readdir(cache_dir2))
    finally
      rm(path, force=true)
    end
  end
end
