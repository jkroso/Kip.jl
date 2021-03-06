__precompile__(true)

module Kip # start of module
using Pkg
using ProgressMeter
using MacroTools
import LibGit2
import Dates

include("./deps.jl")

__init__() = begin
  global home = get(ENV, "KIP_DIR", joinpath(homedir(), ".kip"))
  global repos = joinpath(home, "repos")
  global refs = joinpath(home, "refs")
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
      repo = LibGit2.GitRepo(repopath)
      LibGit2.branch!(repo, "master")
      LibGit2.fetch(repo)
      LibGit2.merge!(repo, fastforward=true)
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

function checkout_repo(repo::LibGit2.GitRepo, username, reponame, tag)
  # Can't do anything with a dirty repo so we have to use it as is
  LibGit2.isdirty(repo) && return LibGit2.path(repo)

  head_name = LibGit2.Consts.HEAD_FILE
  try
    LibGit2.with(LibGit2.head(repo)) do head_ref
      head_name = LibGit2.shortname(head_ref)
      # if it is HEAD use short OID instead
      if head_name == LibGit2.Consts.HEAD_FILE
        head_name = string(LibGit2.GitHash(head_ref))
      end
    end
  catch
  end

  # checkout the specified tag/branch/commit
  if head_name == tag
    nothing # already in the right place
  elseif isnothing(tag)
    LibGit2.branch!(repo, "master")
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
function require(path::AbstractString; locals...)
  require(path, source_dir(); locals...)
end

const modules = Dict{String,Module}()

yesterday() = Dates.now() - Dates.Day(1)
lastchange(file) = Dates.unix2datetime(mtime(file))

"Require `path` relative to `base`"
function require(path::AbstractString, base::AbstractString; locals...)
  if occursin(absolute_path, path)
    load_module(complete(path)...; locals...)
  elseif occursin(relative_path, path)
    load_module(complete(normpath(base, path))...; locals...)
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
            update_pkg(base, repo, tag)
          else
            add_pkg(repo, tag)
          end
          deps = Pkg.TOML.parsefile(joinpath(base, "Project.toml"))["deps"]
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
      load_module(file, pkgname; locals...)
    end
  end
end

function is_installed(base, pkgname)
  file = joinpath(base, "Project.toml")
  isfile(file) && haskey(Pkg.TOML.parsefile(file)["deps"], pkgname)
end

function add_pkg(repo, tag)
  remote = LibGit2.get(LibGit2.GitRemote, repo, LibGit2.remotes(repo)[1])
  url = String(split(string(remote), ' ')[end])
  Pkg.add(Pkg.PackageSpec(url=url, rev=isnothing(tag) ? "master" : tag))
end

function update_pkg(base, repo, tag)
  if lastchange(joinpath(base, "Project.toml")) < yesterday()
    rm(joinpath(base, "Project.toml"))
    rm(joinpath(base, "Manifest.toml"), force=true)
    add_pkg(repo, tag)
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
    haskey(Pkg.TOML.parsefile(path), "name")
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

function load_module(path, name; locals...)
  haskey(modules, path) && return modules[path]
  mod = get_module(path, name)
  Core.eval(mod, Expr(:toplevel, [:(const $k = $v) for (k,v) in locals]...))
  Base.include(mod, path)
  mod
end

"""
Import objects from another file by name

```julia
@use "./user" User Address
```

The above code will import `User` and `Address` from the file `@dirname()/user.jl`.
If you want to use a different name for one of these variables to what they are named
in there own file you can do this by:

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
@use "github.com/jkroso/Emitter.jl/main.jl" emit
```

To load submodules there is a convenient syntax available

```julia
@use "github.com/jkroso/Units.jl" ton [
  "./Imperial" ft
  "./Money" USD
]
```

NB: You don't actually need to specify the file you want out of the repository
in this case since by default it assumes its the file called "main.jl". It will
also try "src/Emitter.jl" hence native modules are fully supported and should
feel as first class as a module which is designed for Kip.jl

To load a registered module just use its registered url. Note that in this case
its actually loaded using the native module system under the hood.
"""
macro use(first, rest...)
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
    append!(names, filter(Base.names(m, true)) do name
      !(name == mn || occursin(r"^(?:[#⭒]|eval$)", String(name)))
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
        for n in Base.names(getfield(m, splat), true)
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

inbrackets(expr) = Meta.isexpr(expr, :vcat) || Meta.isexpr(expr, :hcat) || Meta.isexpr(expr, :vect)
tovcat(n) =
  if Meta.isexpr(n, :hcat) || Meta.isexpr(n, :vect)
    Expr(:vcat, Expr(:row, n.args...))
  else
    Expr(:vcat, map(torow, n.args)...)
  end
torow(n) = Meta.isexpr(n, :row) ? n : Expr(:row, n)

# For backwards compatability
@eval $(Symbol("@require")) = $(getfield(Kip, Symbol("@use")))

export @use, @dirname, @require

end # end of module
