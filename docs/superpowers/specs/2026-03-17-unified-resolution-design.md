# Unified Dependency Resolution for Kip

## Problem

Each Kip module currently gets its own synthetic `Project.toml` in `~/.kip/cache/{hash}/`, and `Pkg.resolve()` is called independently per module. This means Pkg has no global view of version constraints — Module A might resolve `JSON@0.21` while Module B resolves `JSON@0.22`, causing conflicts at runtime.

## Solution

Walk the full `@use` dependency tree via static analysis before any resolution or compilation. Collect every Julia package dependency across all transitive modules, then generate a single unified environment so Pkg resolves everything together with one compatible version set.

## Design

### 1. Static Analysis — Tree Walking

A new function `collect_all_deps(entry_path)` recursively walks the `@use` dependency tree starting from the entry file. For each file it:

1. Reads the source
2. Calls `find_use_packages()` to get Julia package names (`@use PkgName`, `using X`, `import Y`)
3. Calls `find_use_deps()` to get file-based deps (`@use "./foo"`, `@use "github.com/..."`)
4. Recurses into file-based deps
5. Tracks visited files to avoid cycles

Returns:
- A `Set{String}` of all Julia package names needed across the entire tree
- A `Vector{Tuple{String,String}}` of all `(file_path, module_name)` pairs in topological order (deps before dependents)

The tree walk happens once, up front, before any resolution or compilation.

### 2. Unified Environment Resolution

A new function `resolve_environment(entry_path, all_packages)` that:

1. Computes a hash from the sorted set of package names (the env is stable for the same dep set)
2. Creates `~/.kip/envs/{hash}/Project.toml` with the union of all Julia package deps and their UUIDs
3. Runs `Pkg.resolve()` once against this environment to produce a single `Manifest.toml`
4. Returns the env dir path

Cache invalidation: if the set of packages changes (a file adds a new `@use PkgName`), the hash changes, triggering a new resolution. Old envs can be cleaned up lazily.

### 3. Per-Module Cache Packages

`create_cache_package` still exists but is simplified:

- Still creates `~/.kip/cache/{hash}/` with a `Project.toml` and wrapper `src/{name}.jl` for `compilecache`
- **No longer calls `Pkg.resolve()`**
- The `[deps]` section lists packages that specific module uses (needed for `compilecache`), with UUIDs from the already-resolved unified manifest
- No per-module `Manifest.toml`

At runtime, the unified env dir is on `LOAD_PATH`, so `compilecache` finds all packages through the shared environment.

### 4. Entry Point Orchestration

The first `@use` in the entry file triggers orchestration:

1. Detect if we've already resolved for this entry file (via `_resolved_entries` dict). If not:
   - Run `collect_all_deps(entry_file)` to walk the full tree
   - Run `resolve_environment(entry_file, all_packages)` to get the unified env
   - Push the unified env dir onto `LOAD_PATH`
   - Create all per-module cache packages (using UUIDs from the unified manifest)
   - Push all cache dirs onto `LOAD_PATH`
   - Run `precompile_deps!` to ensure `.ji` files exist in dependency order
2. Subsequent `@use` calls skip orchestration — the environment is already set up

Global state:
```julia
const _resolved_entries = Dict{String, String}()  # entry_path => env_dir
```

The `@use PkgName` path changes from `Pkg.add` to `Base.require` against the already-resolved environment. No more `Pkg.activate` / `Pkg.add` / `Pkg.instantiate` at macro time.

### 5. What Gets Removed / Simplified

- `Pkg.resolve()` inside `create_cache_package` — deleted
- `Pkg.add` / `Pkg.instantiate` in the `@use` macro — replaced with `Base.require` against unified env
- `Pkg.activate(base)` in `require()` for pkg3 github repos — uses unified env instead
- Per-module `Manifest.toml` generation — gone
- `installed()` function — no longer needed
- `is_installed()` / `add_pkg()` / `update_pkg()` — no longer needed

`precompile_deps!` stays but is simplified — no longer calls `create_cache_package` itself since all cache packages are created up front during orchestration. Just ensures `.ji` files exist in the right order.

## Key Decisions

- **One environment per entry point** — keeps environments isolated and reproducible
- **Environment stored in cache** (`~/.kip/envs/{hash}/`) — doesn't modify user's workspace
- **Kip owns all Project.toml generation** — users never need their own Project.toml
- **Handles `using`/`import` as well as `@use`** — static analysis picks up all package dependency forms
