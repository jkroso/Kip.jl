# Unified Dependency Resolution for Kip

## Problem

Each Kip module currently gets its own synthetic `Project.toml` in `~/.kip/cache/{hash}/`, and `Pkg.resolve()` is called independently per module. This means Pkg has no global view of version constraints — Module A might resolve `JSON@0.21` while Module B resolves `JSON@0.22`, causing conflicts at runtime.

## Solution

Walk the full `@use` dependency tree via static analysis before any resolution or compilation. Collect every Julia package dependency across all transitive modules, then generate a single unified environment so Pkg resolves everything together with one compatible version set. Pkg picks the latest compatible version of each package — there are no user-specified compat bounds, but the key property is that every module in the tree sees the same version.

## Design

### 1. Static Analysis — Tree Walking

A new function `collect_all_deps(entry_path)` recursively walks the `@use` dependency tree starting from the entry file. For each file it:

1. Reads the source
2. Calls `find_use_packages()` to get Julia package names (`@use PkgName`, `using X`, `import Y`)
3. Calls `find_use_deps()` to get file-based deps (`@use "./foo"`, `@use "github.com/..."`)
4. Recurses into file-based deps
5. Tracks visited files to avoid cycles

For GitHub deps that are not yet cloned, the tree walk triggers `getrepo()` to clone them (same as current behavior in `require()`). This is acceptable since it only happens once per dep.

Returns:
- A `Set{String}` of all Julia package names needed across the entire tree
- A `Vector{Tuple{String,String}}` of all `(file_path, module_name)` pairs in dependency order (post-order DFS — deps before dependents). This ordering is used directly by the orchestration step to create cache packages and compile `.ji` files in the correct order, replacing the recursive `precompile_deps!` approach.

### 2. Unified Environment Resolution

A new function `resolve_environment(all_packages)` that:

1. Computes a hash from the sorted set of package names (the env is stable for the same dep set)
2. Creates `~/.kip/envs/{hash}/Project.toml` with the union of all Julia package deps and their UUIDs
3. Calls `Pkg.resolve()` then `Pkg.instantiate()` against this environment to produce a `Manifest.toml` and download all package source/artifacts
4. Returns the env dir path

Cache invalidation: if the set of packages changes (a file adds a new `@use PkgName`), the hash changes, triggering a new resolution.

**Non-registry packages (GitHub URL deps that are Pkg3 packages):** During the tree walk, if a GitHub dep is detected as a Pkg3 package (via `is_pkg3_pkg`), it is added to the unified environment via `Pkg.develop(path=local_clone_path)` or `Pkg.add(url=...)` during the resolution step, rather than just listing it by UUID. This ensures Pkg can find and resolve it alongside registry packages.

### 3. Per-Module Cache Packages

`create_cache_package` still exists but is simplified:

- Still creates `~/.kip/cache/{hash}/` with a `Project.toml` and wrapper `src/{name}.jl` for `compilecache`
- **No longer calls `Pkg.resolve()`**
- The `[deps]` section lists packages that specific module uses (needed for `compilecache`), with UUIDs from the already-resolved unified manifest
- No per-module `Manifest.toml` — instead, a symlink to the unified `Manifest.toml` is placed in each cache package dir so `compilecache` subprocesses can find package locations

The `compilecache` subprocess mechanism: Julia's `Base.compilecache` spawns a subprocess with `--project=<pkg_dir>`. By symlinking the unified `Manifest.toml` into each cache package dir, the subprocess sees the full resolved dependency set. Additionally, `JULIA_LOAD_PATH` is set to include the unified env dir before calling `Base.compilecache`, ensuring the subprocess can locate all packages.

### 4. Entry Point Orchestration

The entry file is determined by `source_dir()` / `entry_path()` (existing logic: `ARGS[end]` for scripts, `pwd()` for REPL). For REPL usage, each unique set of accumulated deps gets its own environment — the hash is based on the package set, not the entry path.

The first `@use` in the entry file triggers orchestration:

1. Detect if we've already resolved for this entry file (via `_resolved_entries` dict). If not:
   - Run `collect_all_deps(entry_file)` to walk the full tree
   - Run `resolve_environment(all_packages)` to get the unified env
   - Push the unified env dir onto `LOAD_PATH`
   - Create all per-module cache packages (using UUIDs from the unified manifest), iterating in the dependency order returned by `collect_all_deps`
   - Push all cache dirs onto `LOAD_PATH`
   - Compile `.ji` files by loading modules in dependency order
2. Subsequent `@use` calls skip orchestration — the environment is already set up

Global state:
```julia
const _resolved_entries = Dict{String, String}()  # entry_path => env_dir
```

**The `@use PkgName` macro rewrite:** The entire symbol-based branch (currently lines 702-722) changes. Instead of calling `Pkg.add`/`Pkg.instantiate` at macro expansion time, it expands to a `Base.require` call. The package is already installed and available because orchestration ran first. The `installed()` check and `Pkg.add` fallback are removed. The macro expands to:
```julia
quote
  $(esc(Meta.parse(import_str)))  # e.g. `import SQLite: DBInterface`
end
```
Where the `import` statement works because the unified env is on `LOAD_PATH`.

**Dependencies added after orchestration:** If a user adds a new `@use SomePackage` to a file and re-runs, orchestration re-triggers because the file content has changed (the entry file's hash differs, or for REPL usage the package is not in the current unified env). If running in a long-lived REPL session, the user must restart Julia — this is the same constraint as standard Julia environments.

### 5. What Gets Removed / Simplified

- `Pkg.resolve()` inside `create_cache_package` — deleted
- The entire `@use PkgName` macro branch that does `Pkg.add` / `Pkg.instantiate` — replaced with plain `import`/`using` against unified env
- `Pkg.activate(base)` in `require()` for pkg3 github repos — uses unified env instead
- Per-module `Manifest.toml` generation — replaced with symlink to unified manifest
- `installed()` function — no longer needed
- `is_installed()` / `add_pkg()` / `update_pkg()` — no longer needed
- `precompile_deps!` recursive approach — replaced by iterating the topological order from `collect_all_deps`

## Key Decisions

- **One environment per entry point** — keeps environments isolated and reproducible
- **Environment stored in cache** (`~/.kip/envs/{hash}/`) — doesn't modify user's workspace
- **Kip owns all Project.toml generation** — users never need their own Project.toml
- **Handles `using`/`import` as well as `@use`** — static analysis picks up all package dependency forms
- **No user-specified compat bounds** — Pkg picks latest compatible versions; the guarantee is global consistency, not pinning
- **Restart required for new deps in REPL** — same constraint as standard Julia; scripts re-trigger orchestration automatically

## Limitations

- Dependencies added to files after orchestration has run in a REPL session require a Julia restart to take effect
- No `[compat]` bounds — all packages resolve to their latest compatible versions
- Multiple entry points in the same Julia session could theoretically conflict on `LOAD_PATH` if they need different versions of the same package. In practice this is unlikely since Kip is designed for single-entry-point scripts.
