# Pkg-Free Compilation for Kip Modules

## Problem

Kip's precompilation system uses `Pkg.resolve`, `Pkg.activate`, `Pkg.instantiate`, and `Pkg.Registry` APIs to generate Manifest.toml files and resolve dependencies for synthetic cache packages. This causes endless edge cases — registry staleness, version conflicts, global state side effects, and slow compilation.

## Approach

Eliminate Pkg from the compilation path entirely by using `Base.require(PkgId(...))` to pre-load all dependencies in the wrapper module, and propagating `LOAD_PATH` to the compilecache subprocess via `JULIA_LOAD_PATH`. Pkg is retained only for auto-installing missing packages via `Pkg.add` in the `@use` macro.

## Design

### 1. Wrapper generation (`create_cache_package`)

The wrapper already injects Kip via `Base.require(PkgId(...))`. Extend this pattern to all dependencies:

```julia
module Foo_abc123
const _Kip = Base.require(Base.PkgId(Base.UUID("..."), "Kip"))
const var"@use" = getfield(_Kip, Symbol("@use"))
const var"@dirname" = getfield(_Kip, Symbol("@dirname"))
const require = getfield(_Kip, :require)
# Pre-load Julia package deps
Base.require(Base.PkgId(Base.UUID("..."), "JSON3"))
# Pre-load Kip file deps
Base.require(Base.PkgId(Base.UUID("..."), "Helper_def456"))
Base.include(@__MODULE__, "/path/to/original.jl")
end
```

- **Project.toml** still written with `[deps]` name-to-UUID mappings (needed for `Base.identify_package` when the original source does `using JSON3`)
- **No Manifest.toml** generated — no `Pkg.resolve` call

### 2. Signature change for `create_cache_package`

```julia
function create_cache_package(path, hash, name, source;
                               file_deps=Tuple{String,String}[],  # (dep_path, dep_cache_name)
                               output_dir=nothing)
```

- New `file_deps` parameter: list of `(path, cache_name)` pairs for Kip file deps, so wrapper can emit `Base.require` lines for them
- `env_dir` parameter removed entirely

### 3. Deletions

- **`resolve_environment`** — deleted entirely. No more unified env creation.
- **`envs` directory** — the `joinpath(home, "envs")` concept is removed from `__init__`.

### 4. `find_pkg_uuid` without `Pkg.Registry`

Current fallback chain: stdlib -> loaded_modules -> active manifest -> `Pkg.Registry`.

New fallback chain: stdlib -> loaded_modules -> active manifest -> **direct registry file reads**.

```julia
const _registry_cache = Ref{Union{Nothing, Dict{String,String}}}(nothing)

function registry_uuid(name::String)
  cache = _registry_cache[]
  if isnothing(cache)
    cache = Dict{String,String}()
    for reg_dir in readdir(joinpath(first(DEPOT_PATH), "registries"), join=true)
      reg_file = joinpath(reg_dir, "Registry.toml")
      isfile(reg_file) || continue
      reg = TOML.parsefile(reg_file)
      for (uuid, info) in get(reg, "packages", Dict())
        cache[info["name"]] = uuid
      end
    end
    _registry_cache[] = cache
  end
  get(cache, name, nothing)
end
```

Replaces the `Pkg.Registry` block in `find_pkg_uuid`.

### 5. LOAD_PATH propagation

Before any `Base.compilecache` call, serialize the current `LOAD_PATH` into `JULIA_LOAD_PATH` so the subprocess can locate packages:

```julia
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

Wraps `Base.compilecache` calls in `load_from_cache`, `compile_single`, and `ensure_compiled!`.

### 6. Test updates

The test "transitive 3rd party package deps resolve in cache manifest" currently asserts a Manifest.toml exists with JSON3. Update to assert the wrapper `.jl` contains a `Base.require` line for JSON3 instead.

## What stays unchanged

- `Pkg.add` in the `@use` macro for auto-install of missing packages
- `Pkg.add` / `Pkg.activate` in `require` for Pkg3 github repos
- `import Pkg` remains in the module
- All other test scenarios (simple modules, local deps, stdlib, init hooks, etc.)
