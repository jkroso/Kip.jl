__precompile__(true)

module Kip # start of module
using ProgressMeter
using MacroTools
using Git
import LibGit2
import TOML
import SHA

include("./deps.jl")

const _Pkg = Ref{Module}()
function pkg()
  isassigned(_Pkg) || (_Pkg[] = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")))
  _Pkg[]
end

__init__() = begin
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
    dir == "src" ? basename(dirname(dirname(path))) : dir
  elseif isdirpath(path)
    basename(dirname(path))
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
        pkg().activate(base) do
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
  pkg().add(pkg().PackageSpec(url=url, rev=isnothing(tag) ? "master" : tag))
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

const kip_uuid = "c32b5c58-9bcc-11e8-1f8b-492a5c8a885c"

"Scan source for @use PkgName patterns and return package names"
function find_use_packages(source::String)
  pkgs = String[]
  for line in split(source, "\n")
    line = strip(line)
    # Match @use PkgName, @use PkgName:..., @use PkgName.sub, @use PkgName name1 name2
    # Package names start with uppercase; paths start with "
    m = match(r"^@use\s+([A-Z]\w*)", line)
    !isnothing(m) && m[1] ∉ pkgs && push!(pkgs, m[1])
    # Also match @use (PkgName.sub)
    m2 = match(r"^@use\s+\(?([A-Z]\w*)[\.\)]", line)
    !isnothing(m2) && m2[1] ∉ pkgs && push!(pkgs, m2[1])
  end
  pkgs
end

"Scan source for @use path patterns and return resolved local file paths"
function find_use_paths(source::String, base::String)
  paths = String[]
  for line in split(source, "\n")
    line = strip(line)
    m = match(r"^@use\s+\"([^\"]+)\"", line)
    isnothing(m) && continue
    p = m[1]
    if occursin(absolute_path, p)
      push_unique!(paths, first(complete(p)))
    elseif occursin(relative_path, p)
      push_unique!(paths, first(complete(normpath(base, p))))
    else
      # Handle github.com URLs
      gm = match(gh_shorthand, p)
      if !isnothing(gm)
        username, reponame, tag, subpath = gm.captures
        pkgn = splitext(reponame)[1]
        try
          repo = getrepo(username, reponame)
          if !is_pkg3_pkg(LibGit2.path(repo))
            package = checkout_repo(repo, username, reponame, tag)
            file, _ = if isnothing(subpath)
              complete(package, pkgn)
            else
              complete(joinpath(package, subpath))
            end
            push_unique!(paths, file)
          end
        catch e
          @debug "Failed to resolve github dep $p" exception=e
        end
      end
    end
  end
  paths
end
push_unique!(v, x) = x ∉ v && push!(v, x)

"""
Pre-compile all @use path deps (recursively) so their cache dirs are on LOAD_PATH
before we compile the parent module. Returns list of cache dirs added to LOAD_PATH.
"""
function precompile_deps!(path::String)
  dirs = String[]
  source = read(path, String)
  base = dirname(path)
  for dep_path in find_use_paths(source, base)
    # Recursively pre-compile this dep's deps first
    append!(dirs, precompile_deps!(dep_path))
    # Now compile this dep (load_from_cache handles caching/noprecompile)
    dep_source = read(dep_path, String)
    hash = source_hash(dep_source)
    dep_name = replace(splitext(basename(dep_path))[1], r"[^\w]" => "_")
    cache_name = dep_name * "_" * hash[1:12]
    pkg_dir = joinpath(cache, hash)
    # Ensure the cache package dir exists and is on LOAD_PATH
    if !isdir(joinpath(pkg_dir, "src"))
      create_cache_package(dep_path, hash, cache_name, dep_source)
    end
    if pkg_dir ∉ LOAD_PATH
      pushfirst!(LOAD_PATH, pkg_dir)
      push!(dirs, pkg_dir)
    end
  end
  dirs
end

"Look up a package's UUID from loaded modules, stdlib, or the environment manifest"
function find_pkg_uuid(name::String)
  haskey(stdlib_uuids, name) && return stdlib_uuids[name]
  for (pkgid, _) in Base.loaded_modules
    pkgid.name == name && return string(pkgid.uuid)
  end
  manifest = joinpath(dirname(Base.active_project()), "Manifest.toml")
  if isfile(manifest)
    m = TOML.parsefile(manifest)
    deps = get(m, "deps", Dict())
    if haskey(deps, name) && !isempty(deps[name])
      return deps[name][1]["uuid"]
    end
  end
  nothing
end

"Create a synthetic package for compilecache"
function create_cache_package(path::String, hash::String, name::String, source::String=read(path, String))
  pkg_dir = joinpath(cache, hash)
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

  # Resolve manifest if we have Julia package deps and no Manifest yet
  # Skip in compilecache subprocess — Pkg.resolve triggers auto-precompilation that
  # uses a different environment without our LOAD_PATH entries
  if !isempty(use_pkgs) && !isfile(joinpath(pkg_dir, "Manifest.toml")) && !Base.generating_output()
    try
      old_auto = get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", nothing)
      ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
      pkg().activate(pkg_dir) do
        redirect_stderr(devnull) do
          pkg().resolve(io=devnull)
        end
      end
      if isnothing(old_auto)
        delete!(ENV, "JULIA_PKG_PRECOMPILE_AUTO")
      else
        ENV["JULIA_PKG_PRECOMPILE_AUTO"] = old_auto
      end
    catch e
      @debug "Pkg.resolve failed for cache package" exception=e
    end
  end

  # Generate wrapper source
  if has_kip_macros
    # Inject Kip via Base.require(PkgId) to bypass manifest check
    write(joinpath(src_dir, "$name.jl"), """
    module $name
    const _Kip = Base.require(Base.PkgId(Base.UUID("$kip_uuid"), "Kip"))
    const var"@use" = getfield(_Kip, Symbol("@use"))
    const var"@dirname" = getfield(_Kip, Symbol("@dirname"))
    const require = getfield(_Kip, :require)
    Base.include(@__MODULE__, $(repr(path)))
    end
    """)
  else
    write(joinpath(src_dir, "$name.jl"), """
    module $name
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
  cache_name = replace(name, r"[^\w]" => "_") * "_" * hash[1:12]
  pkg_id = Base.PkgId(deterministic_uuid(hash), cache_name)

  # Skip if previously marked as non-precompilable
  nocompile_marker = joinpath(cache, hash, ".noprecompile")
  isfile(nocompile_marker) && return nothing

  # Check for existing compiled cache
  pkg_dir = joinpath(cache, hash)
  cache_dir = Base.compilecache_dir(pkg_id)
  if isdir(cache_dir)
    for f in readdir(cache_dir)
      endswith(f, ".ji") || continue
      ji_path = joinpath(cache_dir, f)
      ocache = Base.ocachefile_from_cachefile(ji_path)
      ocache_path = isfile(ocache) ? ocache : nothing
      try
        mod = Base._require_from_serialized(pkg_id, ji_path, ocache_path, path)
        # In a compilecache subprocess, ensure the cache package is on LOAD_PATH
        # so Julia can locate this dep's source when serializing the parent module
        if Base.generating_output()
          isdir(joinpath(pkg_dir, "src")) || create_cache_package(path, hash, cache_name, source)
          pushfirst!(LOAD_PATH, pkg_dir)
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
  # Pre-compile path-based @use deps so their cache dirs are on LOAD_PATH
  # when _require_from_serialized loads this module's .ji and its deps
  dep_dirs = precompile_deps!(path)
  pkg_dir, pkg_id = create_cache_package(path, hash, cache_name, source)
  src_path = joinpath(pkg_dir, "src", "$cache_name.jl")
  # Push cache package onto LOAD_PATH so subprocess can resolve deps
  pushfirst!(LOAD_PATH, pkg_dir)
  # Suppress Pkg auto-precompilation noise in the compilecache subprocess
  old_auto = get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", nothing)
  ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
  try
    ji_path, ocache_path = Base.compilecache(pkg_id, src_path)
    return Base._require_from_serialized(pkg_id, ji_path, ocache_path, src_path)
  catch e
    # Mark as non-precompilable so we don't retry
    mkpath(dirname(nocompile_marker))
    bt = catch_backtrace()
    write(nocompile_marker, sprint(showerror, e, bt))
    rethrow()
  finally
    if isnothing(old_auto)
      delete!(ENV, "JULIA_PKG_PRECOMPILE_AUTO")
    else
      ENV["JULIA_PKG_PRECOMPILE_AUTO"] = old_auto
    end
    # In a compilecache subprocess, keep cache dirs on LOAD_PATH so Julia can
    # locate dependency sources when serializing the parent module
    if !Base.generating_output()
      filter!(p -> p != pkg_dir && p ∉ dep_dirs, LOAD_PATH)
    end
  end
end

function load_module(path, name)
  haskey(modules, path) && return modules[path]
  mod = try
    load_from_cache(path, name)
  catch e
    # Inside a compilecache subprocess, don't fall back to get_module+include
    # because creating anonymous modules breaks incremental compilation
    Base.generating_output() && rethrow()
    @debug "Cache compilation failed for $path, falling back to include" exception=e
    nothing
  end
  if isnothing(mod)
    # Inside a compilecache subprocess, we can't fall back to get_module+include
    # because creating anonymous modules via eval breaks incremental compilation
    Base.generating_output() && error("Cannot precompile $path: cache compilation failed or was skipped")
    mod = get_module(path, name)
    Base.include(mod, path)
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
    return quote
      old = Base.ACTIVE_PROJECT[]
      Base.ACTIVE_PROJECT[] = @dirname()
      if !Base.generating_output()
        installed($(string(pkg))) || pkg().add($(string(pkg)))
        pkg().instantiate()
      end
      $(esc(Meta.parse(str)))
      Base.ACTIVE_PROJECT[] = old
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
  active_dir = Base.ACTIVE_PROJECT[]
  file = joinpath(active_dir, "Project.toml")
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

export @use, @dirname

end # end of module
