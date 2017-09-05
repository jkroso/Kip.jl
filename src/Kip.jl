__precompile__(true)

module Kip # start of module
using ProgressMeter
using MacroTools

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
  ([\w-.]+)     # username
  /
  ([\w-.]+)     # repo
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
      warn("unable to update $repopath")
    end
  end

isrepo(dir) = isdir(joinpath(dir, ".git"))

gitrepos(dir) = begin
  isrepo(dir) && return [dir]
  children = filter(isdir, map(n->joinpath(dir,n), readdir(dir)))
  reduce(append!, [], map(gitrepos, children))
end

"""
symlink a package which you are developing locally so that it can be
`@require`d as if it was remote. This just save you running `Kip.update()`
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
  name = match(r"github.com/([\w-.]+/[\w-.]+)\.git", url)[1]
  joinpath(repos, name)
end

"""
Convert a `spec` used in a `@require` call to its local storage location
"""
dir(spec::String) = begin
  user,reponame = match(gh_shorthand, spec).captures
  joinpath(repos, user, reponame)|>realpath
end

##
# Run Julia's conventional install hook
#
function build(pkg::AbstractString)
  deps = joinpath(pkg, "deps")
  isdir(deps) && isfile(joinpath(deps, "build.jl")) && cd(build, deps)
end
build() = run(`julia build.jl`)

pkgname(path::AbstractString) =
  splitext(basename(isdirpath(path) ? dirname(path) : splitext(path)[1]))[1]

##
# Try some sensible defaults if `path` doesn't already refer to
# a file
#
function complete(path::AbstractString, pkgname::AbstractString=pkgname(path))
  for p in (path,
            path * ".jl",
            joinpath(path, "main.jl"),
            joinpath(path, "src", pkgname * ".jl"))
    isfile(p) && return (realpath(p), pkgname)
  end

  error("$path can not be completed to a file")
end

##
# Resolve a require call to an absolute file path
#
function resolve(path::AbstractString, base::AbstractString)
  ismatch(absolute_path, path) && return complete(path)
  ismatch(relative_path, path) && return complete(normpath(base, path))
  m = match(gh_shorthand, path)
  @assert m != nothing  "unable to resolve '$path'"
  username,reponame,tag,subpath = m.captures
  pkgname = splitext(reponame)[1]
  if isregistered(username, pkgname)
    path = Pkg.dir(pkgname)
    ispath(path) || Pkg.add(pkgname)
    return complete(path, pkgname)
  end
  package = resolve_github(path)
  build(package)
  if subpath ≡ nothing
    complete(package, pkgname)
  else
    complete(joinpath(package, subpath))
  end
end

function resolve_github(url::AbstractString)
  user,reponame,tag = match(gh_shorthand, url).captures
  localpath = joinpath(repos, user, reponame)
  repo = if isdir(localpath)
    LibGit2.GitRepo(localpath)
  else
    LibGit2.clone("https://github.com/$user/$reponame.git", localpath)
  end

  # Can't do anything with a dirty repo so we have to use it as is
  LibGit2.isdirty(repo) && return localpath

  head_name = LibGit2.Consts.HEAD_FILE
  try
    LibGit2.with(LibGit2.head(repo)) do head_ref
      head_name = LibGit2.shortname(head_ref)
      # if it is HEAD use short OID instead
      if head_name == LibGit2.Consts.HEAD_FILE
        head_name = string(LibGit2.GitHash(head_ref))
      end
    end
  end

  # checkout the specified tag/branch/commit
  if head_name == tag
    nothing # already in the right place
  elseif tag ≡ nothing
    LibGit2.branch!(repo, "master")
  elseif ismatch(semver_regex, tag)
    tags = LibGit2.tag_list(repo)
    v,idx = findmax(semver_query(tag), VersionNumber(t) for t in tags)
    @assert idx > 0 "$user/$reponame has no tag matching $tag. Try again after running Kip.update()"
    LibGit2.checkout!(repo, LibGit2.revparseid(repo, tags[idx]) |> string)
  else
    branch = LibGit2.lookup_branch(repo, tag)
    @assert !isnull(branch) "$repo has no branch $tag"
    LibGit2.branch!(repo, tag)
  end

  # make a copy of the repository in its current state
  dest = joinpath(refs, user, reponame, string(LibGit2.head_oid(repo)))
  isdir(dest) || snapshot_repo(localpath, dest)
  dest
end

function snapshot_repo(src, dest)
  mkpath(dest)
  for name in readdir(src)
    name != ".git" && cp(joinpath(src, name), joinpath(dest, name))
  end
end

function isregistered(username::AbstractString, pkgname::AbstractString)
  # same name as a registered module
  ispath(Pkg.dir("METADATA", pkgname)) || return false
  url = readstring(Pkg.dir("METADATA", pkgname, "url"))
  m = match(r"github.com/([^/]+)/([^/.]+)", url).captures
  # is a registered module
  username == m[1] && pkgname == m[2]
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

##
# Require `path` relative to the current module
#
function require(path::AbstractString; locals...)
  require(path, source_dir(); locals...)
end

const modules = Dict{String,Module}()

##
# Require `path` relative to `base`
#
function require(path::AbstractString, base::AbstractString; locals...)
  path, pkgname = resolve(path, base)
  get!(modules, path) do
    eval_module(Symbol(pkgname), path; locals...)
  end
end

function eval_module(name::Symbol, path::AbstractString; locals...)
  # if installed in native location then load it using native system
  if startswith(path, Pkg.dir())
    return eval(:(import $name; $name))
  end

  # prefix with a ⭒ to avoid clashing with variables inside the module
  mod = Module(Symbol(:⭒, name))

  eval(mod, Expr(:toplevel,
                 :(using Kip),
                 :(eval(x) = Main.Core.eval($mod, x)),
                 :(eval(m, x) = Main.Core.eval(m, x)),
                 [:(const $k = $v) for (k,v) in locals]...,
                 :(include($path))))

  # unpack the submodule if thats all thats in it. For unregistered native modules
  if isdefined(mod, name) && isa(getfield(mod, name), Module)
    getfield(mod, name)
  else
    mod
  end
end

"""
Import objects from another file by name

```julia
@require "./user" User Address
```

The above code will import `User` and `Address` from the file `@dirname()/user.jl`.
If you want to use a different name for one of these variables to what they are named
in there own file you can do this by:

```julia
@require "./user" User => Person
```

To refer to the `Module` object of the file being required:

```julia
@require "./user" => UserModule
```

To load all exported variables verbatim:

```julia
@require "./user" exports...
```

To load a module from github:

```julia
@require "github.com/jkroso/Emitter.jl/main.jl" emit
```

NB: You don't actually need to specify the file you want out of the repository
in this case since by default it assumes its the file called "main.jl". It will
also try "src/Emitter.jl" hence native modules are fully supported and should
feel as first class as a module which is designed for Kip.jl

To load a registered module just use its registered url. Note that in this case
its actually loaded using the native module system under the hood.
"""
macro require(first, rest...)
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
  ast = :(const $name = require($path))
  names = collect(Any, rest) # make array
  if splatall
    m = require(path)
    mn = module_name(m)
    append!(names, filter(Base.names(m, true)) do name
      !(name == mn || ismatch(r"^(?:[#⭒]|eval$)", String(name)))
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
        mn = module_name(m)
        append!(names, filter(n -> n != mn, Base.names(m)))
      else
        for n in Base.names(getfield(m, splat), true)
          n == splat || ismatch(r"^(?:[#⭒]|eval$)", String(n)) && continue
          push!(exprs, :(const $(esc(n)) = getfield(getfield($name, $(QuoteNode(splat))), $(QuoteNode(n)))))
        end
      end
    elseif @capture(n, from_ => to_)
      # support renaming variables as they are imported
      push!(exprs, :(const $(esc(to)) = $name.$from))
    else
      @assert isa(n, Symbol)
      push!(exprs, :(const $(esc(n)) = $name.$n))
    end
  end
  isempty(exprs) ? ast : :(begin $ast; $(exprs...); $name end)
end

export @require, @dirname

end # end of module
