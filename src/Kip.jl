__precompile__(true)

module Kip # start of module
using ProgressMeter
using MacroTools
using Git
import LibGit2
import TOML
import SHA
import Pkg

include("./deps.jl")

__init__() = begin
  global initial_pwd = pwd()
  global home = get(ENV, "KIP_DIR", joinpath(homedir(), ".kip"))
  global repos = joinpath(home, "repos")
  global refs = joinpath(home, "refs")
  global cache = joinpath(home, "cache")
  global stdlib = Set(readdir(Sys.STDLIB))
  global stdlib_uuids = Dict{String,String}()
  for d in readdir(Sys.STDLIB)
    proj = joinpath(Sys.STDLIB, d, "Project.toml")
    if isfile(proj)
      p = TOML.parsefile(proj)
      haskey(p, "name") && haskey(p, "uuid") && (stdlib_uuids[p["name"]] = p["uuid"])
    end
  end
end

const absolute_path = r"^/"
const relative_path = r"^\.{1,2}"
const gh_shorthand = r"
  ^github.com/  # all github paths start the same way
  ([\w\-.]+)    # username
  /
  ([\w\-.]+)    # repo
  (?:@([^/]+))? # commit, tag, branch, or semver query (defaults to latest commit)
  (?:/(.+))?    # path to the module inside the repo (optional)
  $
"x

"""
Update all 3rd party repositories
"""
update() =
  @showprogress "Updating packages..." for repopath in gitrepos(repos)
    try
      cd(repopath) do
        branch = read(git(["symbolic-ref", "--short", "HEAD"], String))|>rstrip
        run(git(["pull", "--ff-only", "origin", branch]))
      end
    catch
      @warn "unable to update $repopath"
    end
  end

isrepo(dir) = isdir(joinpath(dir, ".git"))

gitrepos(dir) = begin
  isrepo(dir) && return [dir]
  children = filter(isdir, map(n->joinpath(dir,n), readdir(dir)))
  reduce(append!, map(gitrepos, children), init=[])
end

"""
symlink a package which you are developing locally so that it can be
`@use`d as if it was remote. This just save you running `Kip.update()`
all the time
"""
link(pkg=pwd()) = begin
  pkg = realpath(pkg)
  from = target_path(pkg)
  from|>dirname|>mkpath
  isdir(from) && rm(from, recursive=true)
  islink(from) && rm(from)
  symlink(pkg, from)
end

"""
Remove a symlink created by `link()`
"""
unlink(pkg=pwd()) = begin
  from = target_path(pkg)
  islink(from) && rm(from)
end

target_path(pkg) = begin
  repo = LibGit2.GitRepo(pkg)
  remote = LibGit2.remotes(repo)[1]
  url = LibGit2.get(LibGit2.GitRemote, repo, remote)|>LibGit2.url
  name = match(r"github.com/([\w\-.]+/[\w\-.]+)\.git", url)[1]
  joinpath(repos, name)
end

"""
Convert a `spec`, as in `@use [spec]`, to its local storage location
"""
dir(spec::String) = begin
  user,reponame = match(gh_shorthand, spec).captures
  joinpath(repos, user, reponame)|>realpath
end

"Run Julia's conventional install hook"
function build(pkg::AbstractString)
  deps = joinpath(pkg, "deps")
  isdir(deps) && isfile(joinpath(deps, "build.jl")) && cd(build, deps)
end
build() = run(`julia --startup-file=no build.jl`)

"Determine a sensible name for a Package defined in `path`"
pkgname(path::AbstractString) = begin
  name = if basename(path) == "main.jl"
    dir = basename(dirname(path))
    if dir == "src"
      basename(dirname(dirname(path)))
    elseif occursin(r"^[0-9a-f]{40}$", dir)
      # Skip git commit hash directories (e.g. ~/.kip/refs/user/Repo.jl/HASH/main.jl)
      basename(dirname(dirname(path)))
    else
      dir
    end
  elseif isdirpath(path)
    dir = basename(dirname(path))
    if occursin(r"^[0-9a-f]{40}$", dir)
      # Skip git commit hash directories (e.g. ~/.kip/refs/user/Repo.jl/HASH/)
      basename(dirname(dirname(path)))
    else
      dir
    end
  else
    basename(path)
  end
  first(splitext(name))
end

"Try some sensible defaults if `path` doesn't already refer to a file"
function complete(path::AbstractString, pkgname::AbstractString=pkgname(path))
  for p in (path,
            path * ".jl",
            joinpath(path, "main.jl"),
            joinpath(path, "src", pkgname * ".jl"))
    isfile(p) && return (realpath(p), pkgname)
  end

  error("$path can not be completed to a file")
end

function head_name(repo::LibGit2.GitRepo)
  cd(LibGit2.path(repo)) do
    rstrip(read(git(["rev-parse", "--short", "HEAD"]), String))
  end
end

function checkout_repo(repo::LibGit2.GitRepo, username, reponame, tag)
  # Can't do anything with a dirty repo so we have to use it as is
  LibGit2.isdirty(repo) && return LibGit2.path(repo)
  # checkout the specified tag/branch/commit
  if isnothing(tag) || head_name(repo) == tag
    nothing # already in the right place
  elseif occursin(semver_regex, tag)
    tags = LibGit2.tag_list(repo)
    v,idx = findmax(semver_query(tag), VersionNumber(t) for t in tags)
    @assert idx > 0 "$username/$reponame has no tag matching $tag. Try again after running Kip.update()"
    LibGit2.checkout!(repo, LibGit2.revparseid(repo, tags[idx]) |> string)
  else
    branch = LibGit2.lookup_branch(repo, tag)
    @assert !isnothing(branch) "$repo has no branch $tag"
    LibGit2.branch!(repo, tag)
  end

  # make a copy of the repository in its current state
  dest = joinpath(refs, username, reponame, string(LibGit2.head_oid(repo)))
  isdir(dest) || snapshot(repo, dest)
  dest
end

function snapshot(repo, dest)
  mkpath(dest)
  src = LibGit2.path(repo)
  for name in readdir(src)
    name != ".git" && cp(joinpath(src, name), joinpath(dest, name))
  end
  build(dest)
end

"""
Get the directory the current file is stored in. If your in the REPL
it will just return `pwd()`
"""
macro dirname() source_dir() end

function source_dir()
  Base.source_path() ∈ ["" nothing] ? entry_path() : dirname(realpath(Base.source_path()))
end

function entry_path()
  isempty(ARGS) ? pwd() : dirname(joinpath(pwd(), ARGS[end]))
end

"Require `path` relative to the current module"
function require(path::AbstractString)
  require(path, source_dir())
end

const modules = Dict{String,Module}()

"Require `path` relative to `base`"
function require(path::AbstractString, base::AbstractString)
  startswith(path, "~/") && (path = homedir() * path[2:end])
  if occursin(absolute_path, path)
    load_module(complete(path)...)
  elseif occursin(relative_path, path)
    load_module(complete(normpath(base, path))...)
  else
    m = match(gh_shorthand, path)
    @assert m != nothing  "unable to resolve '$path'"
    username,reponame,tag,subpath = m.captures
    pkgname = splitext(reponame)[1]
    repo = getrepo(username, reponame)
    if is_pkg3_pkg(LibGit2.path(repo))
      get!(modules, path) do
        Pkg.activate(base) do
          if is_installed(base, pkgname)
            update_pkg(repo, tag)
          else
            add_pkg(repo, tag)
          end
          deps = TOML.parsefile(joinpath(base, "Project.toml"))["deps"]
          uuid = Base.UUID(deps[pkgname])
          Base.require(Base.PkgId(uuid, pkgname))
        end
      end
    else
      package = checkout_repo(repo, username, reponame, tag)
      file, pkgname = if isnothing(subpath)
        complete(package, pkgname)
      else
        complete(joinpath(package, subpath))
      end
      load_module(file, pkgname)
    end
  end
end

function is_installed(base, pkgname)
  file = joinpath(base, "Project.toml")
  isfile(file) && haskey(TOML.parsefile(file)["deps"], pkgname)
end

function add_pkg(repo, tag)
  remote = LibGit2.get(LibGit2.GitRemote, repo, LibGit2.remotes(repo)[1])
  url = String(split(string(remote), ' ')[end])
  Pkg.add(Pkg.PackageSpec(url=url, rev=isnothing(tag) ? "master" : tag))
end

function update_pkg(repo, tag)
  LibGit2.isdirty(repo) && return
  tag_str = isnothing(tag) ? "master" : tag
  cd(LibGit2.path(repo)) do
    LibGit2.fetch(repo)
    changes = parse(Int, read(git(["rev-list", "HEAD...$tag_str", "--count"]), String))
    changes > 0 && run(git(["checkout", tag_str]))
  end
end

function getrepo(user, repo)
  localpath = joinpath(repos, user, repo)
  if isdir(localpath)
    LibGit2.GitRepo(localpath)
  else
    LibGit2.clone("https://github.com/$user/$repo.git", localpath)
  end
end

function is_pkg3_pkg(dir::String)
  any(("JuliaProject.toml", "Project.toml", "REQUIRE")) do file
    path = joinpath(dir, file)
    isfile(path) || return false
    file == "REQUIRE" && return true
    haskey(TOML.parsefile(path), "name")
  end
end

"Eval a module and return the value of it's last expression"
eval_module(path) = Base.include(get_module(path), path)

function get_module(path, name=pkgname(path); interactive=false)
  get!(modules, path) do
    # prefix with a ⭒ to avoid clashing with variables inside the module
    mod = Module(Symbol(:⭒, name))
    Core.eval(mod, Expr(:toplevel,
                        :(using Kip),
                        interactive ? :(using InteractiveUtils) : nothing,
                        :(eval(x) = Core.eval($mod, x)),
                        :(eval(m, x) = Core.eval(m, x)),
                        :(include(path) = Base.include($mod, path))))
    mod
  end
end

"Generate a deterministic UUID from a content hash string"
function deterministic_uuid(hash::String)
  h = hash[1:min(32, length(hash))]
  h = rpad(h, 32, '0')
  Base.UUID(parse(UInt128, h, base=16))
end

"Get the content hash of a file or source string"
content_hash(path::String) = source_hash(read(path))
source_hash(source) = bytes2hex(SHA.sha256(source))

"Ensure a string is a valid Julia identifier (starts with a letter)"
valid_identifier(s::String) = occursin(r"^[A-Za-z]", s) ? s : "M_" * s

const kip_uuid = "c32b5c58-9bcc-11e8-1f8b-492a5c8a885c"

"Scan source for package dependencies (@use PkgName, using, import)"
function find_use_packages(source::String)
  pkgs = String[]
  for line in split(source, "\n")
    line = strip(line)
    # Match @use PkgName, @use PkgName:..., @use PkgName.sub, @use PkgName name1 name2
    m = match(r"^@use\s+([A-Z]\w*)", line)
    !isnothing(m) && m[1] ∉ pkgs && push!(pkgs, m[1])
    # Also match @use (PkgName.sub)
    m2 = match(r"^@use\s+\(?([A-Z]\w*)[\.\)]", line)
    !isnothing(m2) && m2[1] ∉ pkgs && push!(pkgs, m2[1])
    # Match using/import PkgName
    m3 = match(r"^(?:using|import)\s+([A-Z]\w*)", line)
    !isnothing(m3) && m3[1] ∉ pkgs && push!(pkgs, m3[1])
  end
  pkgs
end

"Scan source for @use path patterns and return resolved (path, name) pairs"
function find_use_deps(source::String, base::String)
  deps = Tuple{String,String}[]
  use_prefix = nothing  # tracks prefix from @use "prefix" [ ... ] blocks
  for line in split(source, "\n")
    line = strip(line)
    # Track @use "prefix" [ bracket blocks
    bm = match(r"^@use\s+\"([^\"]+)\"\s*\[", line)
    if !isnothing(bm)
      use_prefix = bm[1]
      continue
    end
    if !isnothing(use_prefix) && startswith(line, "]")
      use_prefix = nothing
      continue
    end
    # Match sub-paths inside bracket block: "subpath" ...
    if !isnothing(use_prefix)
      sm = match(r"^\"([^\"]+)\"", line)
      if !isnothing(sm)
        p = normpath(use_prefix, sm[1])
        resolve_use_dep!(deps, p, base)
        continue
      end
    end
    m = match(r"^@use\s+\"([^\"]+)\"", line)
    isnothing(m) && continue
    resolve_use_dep!(deps, m[1], base)
    # Also extract inline bracket subpaths: ["subpath" ...] on the same line
    for bm in eachmatch(r"\[\"([^\"]+)\"", line)
      p = normpath(m[1], bm[1])
      resolve_use_dep!(deps, p, base)
    end
  end
  deps
end

function resolve_use_dep!(deps, p, base)
  startswith(p, "~/") && (p = homedir() * p[2:end])
  if occursin(absolute_path, p)
    path, name = complete(p)
    any(d -> d[1] == path, deps) || push!(deps, (path, name))
  elseif occursin(relative_path, p)
    path, name = complete(normpath(base, p))
    any(d -> d[1] == path, deps) || push!(deps, (path, name))
  else
    gm = match(gh_shorthand, p)
    if !isnothing(gm)
      username, reponame, tag, subpath = gm.captures
      pkgn = splitext(reponame)[1]
      try
        repo = getrepo(username, reponame)
        if !is_pkg3_pkg(LibGit2.path(repo))
          package = checkout_repo(repo, username, reponame, tag)
          path, name = if isnothing(subpath)
            complete(package, pkgn)
          else
            complete(joinpath(package, subpath))
          end
          any(d -> d[1] == path, deps) || push!(deps, (path, name))
        end
      catch e
        @debug "Failed to resolve github dep $p" exception=e
      end
    end
  end
end

"""
Walk the full @use dependency tree from an entry file.
Returns (all_packages, file_deps, pkg3_repos) where:
- all_packages: Set{String} of all Julia package names across the tree
- file_deps: Vector{Tuple{String,String}} of (path, name) in post-order (deps before dependents)
- pkg3_repos: Vector{String} of local paths to Pkg3 github repos for the unified environment
"""
function collect_all_deps(entry_path::String)
  all_packages = Set{String}()
  file_deps = Tuple{String,String}[]
  pkg3_repos = String[]
  visited = Set{String}()

  function walk(path::String)
    path in visited && return
    push!(visited, path)
    source = read(path, String)
    base = dirname(path)

    # Collect Julia package names from this file
    for pkg in find_use_packages(source)
      push!(all_packages, pkg)
    end

    # Collect and recurse into file-based deps
    for (dep_path, dep_name) in find_use_deps(source, base)
      walk(dep_path)
    end

    # Collect Pkg3 github repos referenced in this file
    for line in split(source, "\n")
      line = strip(line)
      m = match(r"^@use\s+\"([^\"]+)\"", line)
      isnothing(m) && continue
      gm = match(gh_shorthand, m[1])
      isnothing(gm) && continue
      username, reponame, tag, subpath = gm.captures
      try
        repo = getrepo(username, reponame)
        if is_pkg3_pkg(LibGit2.path(repo))
          localpath = realpath(LibGit2.path(repo))
          localpath ∉ pkg3_repos && push!(pkg3_repos, localpath)
        end
      catch
      end
    end

    # Post-order: add this file after its deps
    name = pkgname(path)
    any(d -> d[1] == path, file_deps) || push!(file_deps, (path, name))
  end

  walk(entry_path)
  (all_packages, file_deps, pkg3_repos)
end

"""
    compile(path::String) -> String

Compile all transitive `@use` deps of a Kip entry file. The entry file acts
as a package context — its deps are compiled into a stable cache directory
derived from the initial PWD, but the entry file itself is not compiled.

Returns the resolved source path of the entry file.
"""
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

"Compile a single file to a .ji cache. Returns .ji path on success, .jl path on failure."
function compile_single(path::String, name::String; output_dir::Union{String,Nothing}=nothing)
  source = read(path, String)
  hash = source_hash(source)
  cache_name = valid_identifier(replace(name, r"[^\w]" => "_") * "_" * hash[1:12])
  pkg_id = Base.PkgId(deterministic_uuid(hash), cache_name)

  # Place the synthetic package in output_dir if provided, otherwise global cache
  file_dep_info = collect_file_dep_info(source, dirname(path))
  pkg_dir, pkg_id = create_cache_package(path, hash, cache_name, source; file_deps=file_dep_info, output_dir)

  # Already compiled? Return existing .ji
  cache_dir = Base.compilecache_dir(pkg_id)
  if isdir(cache_dir)
    for f in readdir(cache_dir)
      endswith(f, ".ji") || continue
      return joinpath(cache_dir, f)
    end
  end
  if pkg_dir ∉ LOAD_PATH
    pushfirst!(LOAD_PATH, pkg_dir)
  end

  # Compile
  src_path = joinpath(pkg_dir, "src", "$cache_name.jl")
  old_auto = get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", nothing)
  old_git_prompt = get(ENV, "GIT_TERMINAL_PROMPT", nothing)
  ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
  ENV["GIT_TERMINAL_PROMPT"] = "0"
  stderr_buf = IOBuffer()
  try
    ji_path, _ = Base.compilecache(pkg_id, src_path, stderr_buf)
    stderr_output = String(take!(stderr_buf))
    isempty(stderr_output) || print(stderr, stderr_output)
    return ji_path
  catch e
    stderr_output = String(take!(stderr_buf))
    isempty(stderr_output) || print(stderr, stderr_output)
    @warn "Compilation failed for $path" exception=e
    return path
  finally
    if isnothing(old_auto)
      delete!(ENV, "JULIA_PKG_PRECOMPILE_AUTO")
    else
      ENV["JULIA_PKG_PRECOMPILE_AUTO"] = old_auto
    end
    if isnothing(old_git_prompt)
      delete!(ENV, "GIT_TERMINAL_PROMPT")
    else
      ENV["GIT_TERMINAL_PROMPT"] = old_git_prompt
    end
  end
end

const _precompiling = Set{String}()


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

const _pkg_deps_loaded = Set{String}()

"""
Ensure all Julia package deps in a file's transitive @use tree are loaded in
the current process. This puts them in Base.loaded_modules so compilecache
passes them as concrete_deps to subprocesses — no Manifest.toml needed.
"""
function ensure_pkg_deps_loaded!(path::String)
  path in _pkg_deps_loaded && return
  push!(_pkg_deps_loaded, path)
  source = read(path, String)
  base = dirname(path)
  # Recurse into file deps first
  for (dep_path, _) in find_use_deps(source, base)
    try ensure_pkg_deps_loaded!(dep_path) catch; end
  end
  # Load Julia package deps using initial_pwd as the project context
  # (that's where @use PkgName installs packages)
  pkgs = filter(find_use_packages(source)) do pkg
    pkg ∉ ("Kip", "Base", "Core", "Main", "InteractiveUtils") && pkg ∉ stdlib
  end
  isempty(pkgs) && return
  old = Base.ACTIVE_PROJECT[]
  Base.ACTIVE_PROJECT[] = initial_pwd
  try
    for pkg in pkgs
      uuid_str = find_pkg_uuid(pkg)
      isnothing(uuid_str) && continue
      pkg_id = Base.PkgId(Base.UUID(uuid_str), pkg)
      haskey(Base.loaded_modules, pkg_id) && continue
      # Install if needed
      if isnothing(Base.locate_package(pkg_id))
        try Pkg.add(pkg) catch; end
      end
      # Load into parent so compilecache passes it as concrete_deps
      try Base.require(pkg_id) catch; end
    end
  finally
    Base.ACTIVE_PROJECT[] = old
  end
end

const _registry_cache = Ref{Union{Nothing, Dict{String,String}}}(nothing)

"Look up a package UUID from uncompressed registries or Pkg.Registry"
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
  uuid = get(cache, name, nothing)
  !isnothing(uuid) && return uuid
  # Fall back to Pkg.Registry for compressed registries (read-only, no side effects)
  try
    Reg = Pkg.Registry
    for reg in Base.invokelatest(Reg.reachable_registries)
      for uuid in Base.invokelatest(Reg.uuids_from_name, reg, name)
        result = string(uuid)
        cache[name] = result
        return result
      end
    end
  catch
  end
  nothing
end

"""
Pre-compile all @use path deps (recursively) so their cache dirs are on LOAD_PATH
and their .ji files exist before we compile the parent module.
Returns list of cache dirs added to LOAD_PATH.
"""
function precompile_deps!(path::String)
  path in _precompiling && return String[]
  push!(_precompiling, path)
  dirs = String[]
  source = read(path, String)
  base = dirname(path)
  for (dep_path, _dep_name) in find_use_deps(source, base)
    # Recursively pre-compile this dep's deps first
    append!(dirs, precompile_deps!(dep_path))
    # Use pkgname(dep_path) for a consistent cache name regardless of how
    # the file was referenced (git hash, relative path, etc.)
    dep_source = read(dep_path, String)
    hash = source_hash(dep_source)
    canonical_name = pkgname(dep_path)
    cache_name = valid_identifier(replace(canonical_name, r"[^\w]" => "_") * "_" * hash[1:12])
    pkg_dir = joinpath(cache, hash)
    pkg_id = Base.PkgId(deterministic_uuid(hash), cache_name)
    # Ensure the cache package dir exists and is on LOAD_PATH
    if !isdir(joinpath(pkg_dir, "src"))
      dep_file_dep_info = collect_file_dep_info(dep_source, dirname(dep_path))
      create_cache_package(dep_path, hash, cache_name, dep_source; file_deps=dep_file_dep_info)
    end
    if pkg_dir ∉ LOAD_PATH
      pushfirst!(LOAD_PATH, pkg_dir)
      push!(dirs, pkg_dir)
    end
    # Ensure .ji exists so the parent's compilecache subprocess can find it,
    # but don't load the module — _require_from_serialized will load deps
    # as part of the parent's dependency chain, avoiding duplicate loads
    if !Base.generating_output() && !isdir(Base.compilecache_dir(pkg_id))
      try
        ensure_compiled!(dep_path)
      catch
        # Compilation failed; parent will also fail or fall back
      end
    end
  end
  dirs
end

"""Compile a file's cache .ji without loading the module into the process.
Used by precompile_deps! to ensure .ji files exist for the parent's
compilecache subprocess without causing duplicate module loads at runtime."""
function ensure_compiled!(path::String, name::String=pkgname(path))
  source = read(path, String)
  hash = source_hash(source)
  cache_name = valid_identifier(replace(name, r"[^\w]" => "_") * "_" * hash[1:12])
  pkg_id = Base.PkgId(deterministic_uuid(hash), cache_name)

  # Already compiled
  cache_dir = Base.compilecache_dir(pkg_id)
  if isdir(cache_dir) && any(endswith(".ji"), readdir(cache_dir))
    return
  end

  # Recursively ensure deps are compiled first
  precompile_deps!(path)

  # Create cache package if needed
  pkg_dir = joinpath(cache, hash)
  if !isdir(joinpath(pkg_dir, "src"))
    file_dep_info = collect_file_dep_info(source, dirname(path))
    create_cache_package(path, hash, cache_name, source; file_deps=file_dep_info)
  end

  # Compile only — don't load
  src_path = joinpath(pkg_dir, "src", "$cache_name.jl")
  old_auto = get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", nothing)
  old_git_prompt = get(ENV, "GIT_TERMINAL_PROMPT", nothing)
  ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
  ENV["GIT_TERMINAL_PROMPT"] = "0"
  try
    Base.compilecache(pkg_id, src_path)
  finally
    if isnothing(old_auto)
      delete!(ENV, "JULIA_PKG_PRECOMPILE_AUTO")
    else
      ENV["JULIA_PKG_PRECOMPILE_AUTO"] = old_auto
    end
    if isnothing(old_git_prompt)
      delete!(ENV, "GIT_TERMINAL_PROMPT")
    else
      ENV["GIT_TERMINAL_PROMPT"] = old_git_prompt
    end
  end
end

"Look up a package's UUID from loaded modules, stdlib, the environment manifest, or the registry"
function find_pkg_uuid(name::String)
  haskey(stdlib_uuids, name) && return stdlib_uuids[name]
  for (pkgid, _) in Base.loaded_modules
    pkgid.name == name && !isnothing(pkgid.uuid) && return string(pkgid.uuid)
  end
  manifest = joinpath(dirname(Base.active_project()), "Manifest.toml")
  if isfile(manifest)
    m = TOML.parsefile(manifest)
    deps = get(m, "deps", Dict())
    if haskey(deps, name) && !isempty(deps[name])
      return deps[name][1]["uuid"]
    end
  end
  # Search registries via direct TOML reads
  uuid = registry_uuid(name)
  !isnothing(uuid) && return uuid
  nothing
end

"Create a synthetic package for compilecache"
function create_cache_package(path::String, hash::String, name::String, source::String=read(path, String); file_deps::Vector{Tuple{String,String}}=Tuple{String,String}[], output_dir::Union{String,Nothing}=nothing)
  pkg_dir = joinpath(something(output_dir, cache), hash)
  src_dir = joinpath(pkg_dir, "src")
  mkpath(src_dir)
  uuid = deterministic_uuid(hash)
  use_pkgs = find_use_packages(source)
  has_kip_macros = occursin(r"@use\b|@dirname\b", source)

  # Build [deps] section with UUIDs for any Julia packages referenced by @use
  deps_toml = ""
  if !isempty(use_pkgs)
    deps_lines = String[]
    for pkg in use_pkgs
      pkg_uuid = find_pkg_uuid(pkg)
      !isnothing(pkg_uuid) && push!(deps_lines, "$pkg = \"$pkg_uuid\"")
    end
    if !isempty(deps_lines)
      deps_toml = "\n[deps]\n" * join(deps_lines, "\n") * "\n"
    end
  end

  write(joinpath(pkg_dir, "Project.toml"), """
  name = "$name"
  uuid = "$uuid"
  $deps_toml""")

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

  (pkg_dir, Base.PkgId(uuid, name))
end

"Try to load a module from the compile cache"
function load_from_cache(path::String, name::String)
  source = read(path, String)
  hash = source_hash(source)
  cache_name = valid_identifier(replace(name, r"[^\w]" => "_") * "_" * hash[1:12])
  pkg_id = Base.PkgId(deterministic_uuid(hash), cache_name)

  nocompile_marker = joinpath(cache, hash, ".noprecompile")

  # If this module was already loaded as a transitive dependency of another module
  # (e.g. BitSet loaded Enum via _require_from_serialized), return it directly
  if haskey(Base.loaded_modules, pkg_id)
    return Base.loaded_modules[pkg_id]
  end

  # Ensure initial_pwd is on LOAD_PATH — this is where @use PkgName installs
  # packages, and the compilecache subprocess needs to locate them there
  if initial_pwd ∉ LOAD_PATH
    pushfirst!(LOAD_PATH, initial_pwd)
  end

  # Ensure Julia package deps are loaded in the parent process before compilation
  ensure_pkg_deps_loaded!(path)

  # Ensure deps' cache dirs are on LOAD_PATH before loading from cache
  # (needed for _require_from_serialized to locate dependency modules)
  dep_dirs = precompile_deps!(path)
  pkg_dir = joinpath(cache, hash)
  if pkg_dir ∉ LOAD_PATH
    pushfirst!(LOAD_PATH, pkg_dir)
    push!(dep_dirs, pkg_dir)
  end

  # Check for existing compiled cache
  cache_dir = Base.compilecache_dir(pkg_id)
  if isdir(cache_dir)
    for f in readdir(cache_dir)
      endswith(f, ".ji") || continue
      ji_path = joinpath(cache_dir, f)
      ocache = Base.ocachefile_from_cachefile(ji_path)
      ocache_path = isfile(ocache) ? ocache : nothing
      try
        mod = Base._require_from_serialized(pkg_id, ji_path, ocache_path, path)
        if Base.generating_output()
          isdir(joinpath(pkg_dir, "src")) || create_cache_package(path, hash, cache_name, source)
        end
        return mod
      catch
        # Stale cache, recompile
        rm(ji_path, force=true)
        !isnothing(ocache_path) && rm(ocache_path, force=true)
      end
    end
  end

  # No valid cache found, compile
  file_dep_info = collect_file_dep_info(source, dirname(path))
  pkg_dir, pkg_id = create_cache_package(path, hash, cache_name, source; file_deps=file_dep_info)
  src_path = joinpath(pkg_dir, "src", "$cache_name.jl")
  # Suppress Pkg auto-precompilation noise and git credential prompts in the compilecache subprocess
  old_auto = get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", nothing)
  old_git_prompt = get(ENV, "GIT_TERMINAL_PROMPT", nothing)
  ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
  ENV["GIT_TERMINAL_PROMPT"] = "0"
  stderr_buf = IOBuffer()
  try
    ji_path, ocache_path = Base.compilecache(pkg_id, src_path, stderr_buf)
    # Print any non-error stderr output (warnings, etc.)
    stderr_output = String(take!(stderr_buf))
    isempty(stderr_output) || print(stderr, stderr_output)
    return Base._require_from_serialized(pkg_id, ji_path, ocache_path, src_path)
  catch e
    # Only mark as non-precompilable for errors that indicate the module
    # is fundamentally incompatible (e.g. eval into closed module, method overwrites)
    stderr_output = String(take!(stderr_buf))
    isempty(stderr_output) || print(stderr, stderr_output)
    err_str = try sprint(showerror, e) catch; string(e) end * "\n" * stderr_output
    if occursin("Evaluation into", err_str) || occursin("overwritten in", err_str) || occursin("Method overwriting", err_str)
      mkpath(dirname(nocompile_marker))
      write(nocompile_marker, err_str)
    end
    rethrow()
  finally
    if isnothing(old_auto)
      delete!(ENV, "JULIA_PKG_PRECOMPILE_AUTO")
    else
      ENV["JULIA_PKG_PRECOMPILE_AUTO"] = old_auto
    end
    if isnothing(old_git_prompt)
      delete!(ENV, "GIT_TERMINAL_PROMPT")
    else
      ENV["GIT_TERMINAL_PROMPT"] = old_git_prompt
    end
  end
end

"""
Load a module with stable identity — paths are normalized via `realpath` so
repeated calls to the same file always return the exact same Module (`===`).
"""
function load_module(path, name=pkgname(path))
  path = realpath(path)
  haskey(modules, path) && return modules[path]
  mod = try
    load_from_cache(path, name)
  catch e
    # Inside a compilecache subprocess, don't fall back to get_module+include
    # because creating anonymous modules breaks incremental compilation
    Base.generating_output() && rethrow()
    @warn "Cache compilation failed for $path, falling back to include" exception=e
    nothing
  end
  if isnothing(mod)
    # Inside a compilecache subprocess, we can't fall back to get_module+include
    # because creating anonymous modules via eval breaks incremental compilation
    Base.generating_output() && error("Cannot precompile $path: cache compilation failed or was skipped")
    mod = get_module(path, name)
    Base.include(mod, path)
    Base.invokelatest() do
      isdefined(mod, :__init__) && mod.__init__()
    end
  end
  modules[path] = mod
  mod
end

"""
Import objects from another file by name

```julia
@use "./user" User Address
```

The above code will import `User` and `Address` from the file `./user.jl`. If
you want to use a different name for one of these variables to what they are
named in there own file you can do this by:

```julia
@use "./user" User => Person
```

To refer to the `Module` object of the file being required:

```julia
@use "./user" => UserModule
```

To load all exported variables verbatim:

```julia
@use "./user" exports...
```

To load a module from github:

```julia
@use "github.com/jkroso/Emitter.jl" emit
```

To load submodules there is a convenient syntax available

```julia
@use "github.com/jkroso/Units.jl" ton [
  "./Imperial" ft
  "./Money" USD
]
```

To load a registerd Julia package

```
@use SQLite: DBInterface
```
"""
macro use(first, rest...)
  if (@capture(first, pkg_Symbol)
   || @capture(first, pkg_Symbol:_)
   || @capture(first, (pkg_Symbol:_,__))
   || @capture(first, (pkg_Symbol...))
   || @capture(first, ((pkg_Symbol._)...))
   || @capture(first, pkg_Symbol._))
    str = replace(repr(first), r"#= [^=]* =#" => "", "()" => "")
    str = replace(str, r"^:\({0,2}([^\)]+)\){0,2}$" => s"import \1")
    str = replace(str, r"^import (.*)\.{3}$" => s"using \1")
    import_expr = Meta.parse(str)
    return quote
      if Kip.initial_pwd ∉ LOAD_PATH
        pushfirst!(LOAD_PATH, Kip.initial_pwd)
      end
      if !Base.generating_output() && isnothing(Base.identify_package($(string(pkg))))
        let old = Base.ACTIVE_PROJECT[]
          try
            Base.ACTIVE_PROJECT[] = Kip.initial_pwd
            Pkg.add($(string(pkg)))
          finally
            Base.ACTIVE_PROJECT[] = old
          end
        end
      end
      $(import_expr)
    end
  end
  splatall = false
  if @capture(first, path_ => name_)
    name = esc(name)
  elseif @capture(first, path_...)
    splatall = true
    name = Symbol(path)
  else
    @assert @capture(first, path_)
    isempty(rest) && return :(require($path))
    name = Symbol(path)
  end
  names = collect(Any, rest) # make array
  if splatall
    m = require(path)
    mn = nameof(m)
    append!(names, filter(Base.names(m)) do name
      name == mn && return false
      !occursin(r"^(?:[#⭒]|eval|include$)", String(name))
    end)
  end
  exprs = []
  for n in names
    if Meta.isexpr(n, :macrocall)
      # support importing macros
      append!(names, n.args)
    elseif @capture(n, splat_...)
      m = require(path)
      if splat == :exports
        mn = nameof(m)
        append!(names, filter(n -> n != mn, Base.names(m)))
      else
        for n in Base.names(getfield(m, splat), all=true)
          n == splat || occursin(r"^(?:[#⭒]|eval$)", String(n)) && continue
          push!(exprs, :(const $(esc(n)) = getfield(getfield($name, $(QuoteNode(splat))), $(QuoteNode(n)))))
        end
      end
    elseif @capture(n, from_ => to_)
      # support renaming variables as they are imported
      push!(exprs, :(const $(esc(to)) = $name.$from))
    elseif inbrackets(n)
      for row in tovcat(n).args
        relpath, rest = (row.args[1], row.args[2:end])
        firstarg = if @capture(relpath, p_ => n_)
          :($(normpath(path, p)) => $n)
        else
          normpath(path, relpath)
        end
        push!(exprs, esc(macroexpand(__module__, Expr(:macrocall, getfield(Kip, Symbol("@use")), __source__, firstarg, rest...))))
      end
    elseif n isa LineNumberNode
    else
      @assert n isa Symbol "Expected a Symbol, got $(repr(n))"
      push!(exprs, :(const $(esc(n)) = $name.$n))
    end
  end
  if isempty(exprs)
    Meta.isexpr(name, :escape) ? :(const $name = require($path)) : :(require($path))
  elseif all(inbrackets, names) # all submodules
    quote $(exprs...) end
  else
    quote
      const $name = require($path)
      $(exprs...)
      $name
    end
  end
end

const empty_deps = Dict{String,Any}()

installed(pkg) = begin
  pkg in stdlib && return true
  file = joinpath(initial_pwd, "Project.toml")
  ispath(file) || return false
  haskey(get(TOML.parsefile(file), "deps", empty_deps), pkg)
end

inbrackets(expr) = Meta.isexpr(expr, :vcat) || Meta.isexpr(expr, :hcat) || Meta.isexpr(expr, :vect)
tovcat(n) =
  if Meta.isexpr(n, :hcat) || Meta.isexpr(n, :vect)
    Expr(:vcat, Expr(:row, n.args...))
  else
    Expr(:vcat, map(torow, n.args)...)
  end
torow(n) = Meta.isexpr(n, :row) ? n : Expr(:row, n)

export @use, @dirname, compile

end # end of module
