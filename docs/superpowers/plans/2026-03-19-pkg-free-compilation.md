# Pkg-Free Compilation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Pkg.resolve/activate/instantiate from Kip's compilation path, using Base.require(PkgId(...)) to pre-load all deps in wrapper modules.

**Architecture:** Wrapper modules emit explicit `Base.require(PkgId(...))` lines for every dependency (Julia packages and Kip file deps). LOAD_PATH is propagated to compilecache subprocesses via JULIA_LOAD_PATH env var. Pkg.Registry is replaced by direct registry TOML reads.

**Tech Stack:** Julia Base internals (compilecache, PkgId, LOAD_PATH), TOML

---

### Task 1: Add `with_load_path` helper and `registry_uuid` function

**Files:**
- Modify: `src/Kip.jl:621-624` (add new helper functions near the constants)

- [ ] **Step 1: Add `with_load_path` helper**

Add after line 624 (after the `_entry_file` const):

```julia
"Propagate current LOAD_PATH to compilecache subprocesses via JULIA_LOAD_PATH"
function with_load_path(f)
  old = get(ENV, "JULIA_LOAD_PATH", nothing)
  paths = String[]
  for p in LOAD_PATH
    if p isa String
      push!(paths, p)
    elseif p == "@"
      push!(paths, "@")
    elseif p == "@stdlib"
      push!(paths, "@stdlib")
    elseif p == "@v#.#"
      push!(paths, "@v#.#")
    end
  end
  ENV["JULIA_LOAD_PATH"] = join(paths, Sys.iswindows() ? ';' : ':')
  try
    f()
  finally
    if isnothing(old)
      delete!(ENV, "JULIA_LOAD_PATH")
    else
      ENV["JULIA_LOAD_PATH"] = old
    end
  end
end
```

- [ ] **Step 2: Add `registry_uuid` function and cache**

Add right after `with_load_path`:

```julia
const _registry_cache = Ref{Union{Nothing, Dict{String,String}}}(nothing)

"Look up a package UUID by reading registry TOML files directly"
function registry_uuid(name::String)
  cache = _registry_cache[]
  if isnothing(cache)
    cache = Dict{String,String}()
    for depot in DEPOT_PATH
      reg_dir = joinpath(depot, "registries")
      isdir(reg_dir) || continue
      for entry in readdir(reg_dir, join=true)
        reg_file = joinpath(entry, "Registry.toml")
        isfile(reg_file) || continue
        reg = TOML.parsefile(reg_file)
        for (uuid, info) in get(reg, "packages", Dict())
          cache[info["name"]] = uuid
        end
      end
    end
    _registry_cache[] = cache
  end
  get(cache, name, nothing)
end
```

- [ ] **Step 3: Commit**

```bash
git add src/Kip.jl
git commit -m "Add with_load_path and registry_uuid helpers"
```

### Task 2: Replace Pkg.Registry in `find_pkg_uuid`

**Files:**
- Modify: `src/Kip.jl:730-755` (`find_pkg_uuid` function)

- [ ] **Step 1: Replace the Pkg.Registry block**

Replace lines 744-753 (the `try` block with `Pkg.Registry`):

```julia
  # Search registries (use invokelatest to avoid world age issues in compilecache subprocesses)
  try
    Reg = Pkg.Registry
    for reg in Base.invokelatest(Reg.reachable_registries)
      for uuid in Base.invokelatest(Reg.uuids_from_name, reg, name)
        return string(uuid)
      end
    end
  catch
  end
```

With:

```julia
  # Search registries via direct TOML reads
  uuid = registry_uuid(name)
  !isnothing(uuid) && return uuid
```

- [ ] **Step 2: Commit**

```bash
git add src/Kip.jl
git commit -m "Replace Pkg.Registry with direct registry file reads"
```

### Task 3: Rewrite `create_cache_package` to emit `Base.require` lines

**Files:**
- Modify: `src/Kip.jl:757-828` (`create_cache_package` function)

- [ ] **Step 1: Change the function signature**

Replace the signature (line 758):

```julia
function create_cache_package(path::String, hash::String, name::String, source::String=read(path, String); env_dir::Union{String,Nothing}=nothing, output_dir::Union{String,Nothing}=nothing)
```

With:

```julia
function create_cache_package(path::String, hash::String, name::String, source::String=read(path, String); file_deps::Vector{Tuple{String,String}}=Tuple{String,String}[], output_dir::Union{String,Nothing}=nothing)
```

- [ ] **Step 2: Remove the Manifest.toml generation block**

Delete lines 784-805 (the entire `if !isempty(use_pkgs) && ...` block that calls `Pkg.activate` and `Pkg.resolve`).

- [ ] **Step 3: Rewrite wrapper source generation**

Replace lines 807-825 (the wrapper generation) with code that emits `Base.require(PkgId(...))` for all deps:

```julia
  # Build Base.require lines for all deps
  require_lines = String[]

  # Julia package deps
  for pkg in use_pkgs
    pkg ∈ ("Kip", "Base", "Core", "Main") && continue
    pkg_uuid = find_pkg_uuid(pkg)
    !isnothing(pkg_uuid) && push!(require_lines,
      "Base.require(Base.PkgId(Base.UUID(\"$pkg_uuid\"), \"$pkg\"))")
  end

  # Kip file deps
  for (dep_path, dep_cache_name) in file_deps
    dep_source = read(dep_path, String)
    dep_hash = source_hash(dep_source)
    dep_uuid = deterministic_uuid(dep_hash)
    push!(require_lines,
      "Base.require(Base.PkgId(Base.UUID(\"$dep_uuid\"), \"$dep_cache_name\"))")
  end

  require_block = join(require_lines, "\n")

  # Generate wrapper source
  if has_kip_macros
    write(joinpath(src_dir, "$name.jl"), """
    module $name
    const _Kip = Base.require(Base.PkgId(Base.UUID("$kip_uuid"), "Kip"))
    const var"@use" = getfield(_Kip, Symbol("@use"))
    const var"@dirname" = getfield(_Kip, Symbol("@dirname"))
    const require = getfield(_Kip, :require)
    $require_block
    Base.include(@__MODULE__, $(repr(path)))
    end
    """)
  else
    write(joinpath(src_dir, "$name.jl"), """
    module $name
    $require_block
    Base.include(@__MODULE__, $(repr(path)))
    end
    """)
  end
```

- [ ] **Step 4: Commit**

```bash
git add src/Kip.jl
git commit -m "Rewrite create_cache_package to emit Base.require for all deps"
```

### Task 4: Update callers to pass `file_deps` and use `with_load_path`

**Files:**
- Modify: `src/Kip.jl` — functions `precompile_deps!`, `ensure_compiled!`, `load_from_cache`, `compile_single`

- [ ] **Step 1: Update `precompile_deps!` (lines 631-675)**

Replace the `env_dir` lookup and `create_cache_package` call. Change lines 648-658 from:

```julia
    # Ensure the cache package dir exists and is on LOAD_PATH
    env_dir = _current_env_dir[]
    if isnothing(env_dir)
      proj = Base.active_project()
      if !isnothing(proj) && isfile(joinpath(dirname(proj), "Manifest.toml"))
        env_dir = dirname(proj)
      end
    end
    if !isdir(joinpath(pkg_dir, "src"))
      create_cache_package(dep_path, hash, cache_name, dep_source; env_dir)
    end
```

To:

```julia
    # Ensure the cache package dir exists and is on LOAD_PATH
    if !isdir(joinpath(pkg_dir, "src"))
      dep_file_deps = find_use_deps(dep_source, dirname(dep_path))
      dep_file_dep_info = Tuple{String,String}[]
      for (fdp, _) in dep_file_deps
        fds = read(fdp, String)
        fdh = source_hash(fds)
        fdn = pkgname(fdp)
        fdcn = valid_identifier(replace(fdn, r"[^\w]" => "_") * "_" * fdh[1:12])
        push!(dep_file_dep_info, (fdp, fdcn))
      end
      create_cache_package(dep_path, hash, cache_name, dep_source; file_deps=dep_file_dep_info)
    end
```

- [ ] **Step 2: Update `ensure_compiled!` (lines 680-728)**

Replace the `env_dir` lookup and `create_cache_package` call. Change lines 697-706 from:

```julia
  # Create cache package if needed
  pkg_dir = joinpath(cache, hash)
  env_dir = _current_env_dir[]
  if isnothing(env_dir)
    proj = Base.active_project()
    if !isnothing(proj) && isfile(joinpath(dirname(proj), "Manifest.toml"))
      env_dir = dirname(proj)
    end
  end
  if !isdir(joinpath(pkg_dir, "src"))
    create_cache_package(path, hash, cache_name, source; env_dir)
  end
```

To:

```julia
  # Create cache package if needed
  pkg_dir = joinpath(cache, hash)
  if !isdir(joinpath(pkg_dir, "src"))
    file_deps = find_use_deps(source, dirname(path))
    file_dep_info = Tuple{String,String}[]
    for (fdp, _) in file_deps
      fds = read(fdp, String)
      fdh = source_hash(fds)
      fdn = pkgname(fdp)
      fdcn = valid_identifier(replace(fdn, r"[^\w]" => "_") * "_" * fdh[1:12])
      push!(file_dep_info, (fdp, fdcn))
    end
    create_cache_package(path, hash, cache_name, source; file_deps=file_dep_info)
  end
```

Wrap the `Base.compilecache` call (line 715) with `with_load_path`:

```julia
  try
    with_load_path() do
      Base.compilecache(pkg_id, src_path)
    end
```

- [ ] **Step 3: Update `load_from_cache` (lines 831-926)**

Replace lines 876-884 (the env_dir lookup and `create_cache_package` call):

```julia
  # No valid cache found, compile
  env_dir = _current_env_dir[]
  if isnothing(env_dir)
    proj = Base.active_project()
    if !isnothing(proj) && isfile(joinpath(dirname(proj), "Manifest.toml"))
      env_dir = dirname(proj)
    end
  end
  pkg_dir, pkg_id = create_cache_package(path, hash, cache_name, source; env_dir)
```

With:

```julia
  # No valid cache found, compile
  file_deps_raw = find_use_deps(source, dirname(path))
  file_dep_info = Tuple{String,String}[]
  for (fdp, _) in file_deps_raw
    fds = read(fdp, String)
    fdh = source_hash(fds)
    fdn = pkgname(fdp)
    fdcn = valid_identifier(replace(fdn, r"[^\w]" => "_") * "_" * fdh[1:12])
    push!(file_dep_info, (fdp, fdcn))
  end
  pkg_dir, pkg_id = create_cache_package(path, hash, cache_name, source; file_deps=file_dep_info)
```

Wrap the `Base.compilecache` call (line 893) with `with_load_path`:

```julia
    ji_path, ocache_path = with_load_path() do
      Base.compilecache(pkg_id, src_path, stderr_buf)
    end
```

Also update line 864-865 — the `generating_output` fallback currently references `env_dir` which no longer exists. Replace:

```julia
        if Base.generating_output()
          isdir(joinpath(pkg_dir, "src")) || create_cache_package(path, hash, cache_name, source; env_dir)
        end
```

With:

```julia
        if Base.generating_output()
          isdir(joinpath(pkg_dir, "src")) || create_cache_package(path, hash, cache_name, source)
        end
```

- [ ] **Step 4: Update `compile_single` (lines 568-619)**

Change the signature from:

```julia
function compile_single(path::String, name::String, env_dir::Union{String,Nothing}; output_dir::Union{String,Nothing}=nothing)
```

To:

```julia
function compile_single(path::String, name::String; output_dir::Union{String,Nothing}=nothing)
```

Replace line 576:

```julia
  pkg_dir, pkg_id = create_cache_package(path, hash, cache_name, source; env_dir, output_dir)
```

With:

```julia
  file_deps_raw = find_use_deps(source, dirname(path))
  file_dep_info = Tuple{String,String}[]
  for (fdp, _) in file_deps_raw
    fds = read(fdp, String)
    fdh = source_hash(fds)
    fdn = pkgname(fdp)
    fdcn = valid_identifier(replace(fdn, r"[^\w]" => "_") * "_" * fdh[1:12])
    push!(file_dep_info, (fdp, fdcn))
  end
  pkg_dir, pkg_id = create_cache_package(path, hash, cache_name, source; file_deps=file_dep_info, output_dir)
```

Wrap the `Base.compilecache` call (line 598) with `with_load_path`:

```julia
    ji_path, _ = with_load_path() do
      Base.compilecache(pkg_id, src_path, stderr_buf)
    end
```

- [ ] **Step 5: Commit**

```bash
git add src/Kip.jl
git commit -m "Update all callers to pass file_deps and use with_load_path"
```

### Task 5: Delete `resolve_environment` and clean up `compile`

**Files:**
- Modify: `src/Kip.jl`

- [ ] **Step 1: Delete `resolve_environment` function**

Delete lines 461-525 (the entire `resolve_environment` function).

- [ ] **Step 2: Simplify `compile` function**

Replace lines 536-566 (the `compile` function) with:

```julia
function compile(path::String)
  path, name = complete(path)
  path = realpath(path)

  # Derive output directory from initial PWD (stable across runs for the same project)
  pwd_hash = bytes2hex(SHA.sha256(Vector{UInt8}(initial_pwd)))[1:16]
  output_dir = joinpath(cache, pwd_hash)
  mkpath(output_dir)

  # Walk the full dependency tree
  all_packages, file_deps, pkg3_repos = collect_all_deps(path)

  # Compile all deps in post-order, skipping the main file itself
  for (dep_path, dep_name) in file_deps
    dep_path == path && continue
    compile_single(dep_path, dep_name; output_dir)
  end
  path
end
```

- [ ] **Step 3: Remove `envs` from `__init__`**

Delete line 20:

```julia
  global envs = joinpath(home, "envs")
```

- [ ] **Step 4: Remove stale constants**

Delete lines 622-624:

```julia
const _resolved_entries = Dict{String, Tuple{String, String}}()  # entry_path => (env_dir, content_hash)
const _current_env_dir = Ref{Union{String,Nothing}}(nothing)  # set by ensure_environment!, read by load_from_cache
const _entry_file = Ref{Union{String,Nothing}}(nothing)  # true entry point, set once on first @use
```

- [ ] **Step 5: Commit**

```bash
git add src/Kip.jl
git commit -m "Delete resolve_environment and clean up compile path"
```

### Task 6: Extract `file_dep_info` helper to reduce duplication

**Files:**
- Modify: `src/Kip.jl`

Tasks 3-4 introduced repeated code for building the `file_dep_info` vector. Extract it.

- [ ] **Step 1: Add helper function**

Add near the other utility functions:

```julia
"Compute (dep_path, cache_name) pairs for all file-based @use deps of a source file"
function collect_file_dep_info(source::String, base::String)
  file_dep_info = Tuple{String,String}[]
  for (fdp, _) in find_use_deps(source, base)
    fds = read(fdp, String)
    fdh = source_hash(fds)
    fdn = pkgname(fdp)
    fdcn = valid_identifier(replace(fdn, r"[^\w]" => "_") * "_" * fdh[1:12])
    push!(file_dep_info, (fdp, fdcn))
  end
  file_dep_info
end
```

- [ ] **Step 2: Replace all inline occurrences**

In `precompile_deps!`, `ensure_compiled!`, `load_from_cache`, and `compile_single`, replace the repeated block with:

```julia
file_dep_info = collect_file_dep_info(source, dirname(path))
```

(or `dep_source` / `dep_path` as appropriate for `precompile_deps!`)

- [ ] **Step 3: Commit**

```bash
git add src/Kip.jl
git commit -m "Extract collect_file_dep_info helper to reduce duplication"
```

### Task 7: Update tests

**Files:**
- Modify: `tests/compile.jl:60-78`

- [ ] **Step 1: Rewrite the transitive deps test**

Replace lines 60-78:

```julia
  @testset "transitive 3rd party package deps resolve in cache manifest" begin
    # Reproduces: "Cannot locate source for PrettyPrinting" when a Kip dep
    # uses a Julia package that isn't in the active project's Manifest.toml
    path = realpath(joinpath(fixtures, "dep_uses_pkg.jl"))
    source = read(path, String)
    hash = Kip.source_hash(source)
    name = Kip.valid_identifier(replace(Kip.pkgname(path), r"[^\w]" => "_") * "_" * hash[1:12])
    pkg_dir = joinpath(Kip.cache, hash)
    # Clean any existing cache so create_cache_package runs fresh
    rm(pkg_dir, recursive=true, force=true)
    # Use the Kip project dir as env_dir — its Manifest does NOT have JSON3
    env_dir = joinpath(@__DIR__, "..")
    Kip.create_cache_package(path, hash, name, source; env_dir)
    manifest_path = joinpath(pkg_dir, "Manifest.toml")
    @test isfile(manifest_path)
    manifest = Kip.TOML.parsefile(manifest_path)
    manifest_deps = get(manifest, "deps", Dict())
    @test haskey(manifest_deps, "JSON3")
  end
```

With:

```julia
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
```

- [ ] **Step 2: Run all tests**

Run: `cd /Users/jake/Desktop/JuliaLang/Kip && julia --project tests/compile.jl`

Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/compile.jl
git commit -m "Update test to verify Base.require in wrapper instead of Manifest.toml"
```

### Task 8: Verify end-to-end and clean up

- [ ] **Step 1: Run full test suite**

Run: `cd /Users/jake/Desktop/JuliaLang/Kip && julia --project tests/compile.jl`

Expected: All tests pass including the 3rd party package loading tests.

- [ ] **Step 2: Clean stale cache**

```bash
rm -rf ~/.kip/cache ~/.kip/envs
```

- [ ] **Step 3: Run tests again from clean cache**

Run: `cd /Users/jake/Desktop/JuliaLang/Kip && julia --project tests/compile.jl`

Expected: All tests pass — cold compilation works without Pkg.resolve.

- [ ] **Step 4: Final commit if any cleanup needed**
