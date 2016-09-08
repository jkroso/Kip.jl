__precompile__(true)

module Kip # start of module

include("./deps.jl")

const home = joinpath(homedir(), ".kip")
const repos = joinpath(home, "repos")
const refs = joinpath(home, "refs")

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
  for user in readdir(repos)
    user = joinpath(repos, user)
    for reponame in readdir(user)
      LibGit2.fetch(LibGit2.GitRepo(joinpath(user, reponame)), refspecs=["master"])
    end
  end

##
# Run Julia's conventional install hook
#
function build(pkg::AbstractString)
  deps = joinpath(pkg, "deps")
  isdir(deps) && cd(deps) do
    run(`julia build.jl`)
  end
end

##
# Try some sensible defaults if `path` doesn't already refer to
# a file
#
function complete(path::AbstractString, pkgname::AbstractString=splitext(basename(path))[1])
  for p in (path,
            path * ".jl",
            joinpath(path, "main.jl"),
            # "src/$(module_name).jl". A Julia convention
            replace(joinpath(path, "src", pkgname), r"(\.jl)?$", ".jl"))
    isfile(p) && return (realpath(p), pkgname)
  end

  error("$path can not be completed to a file")
end

##
# Resolve a require call to an absolute file path
#
function resolve(path::AbstractString, base::AbstractString)
  ismatch(absolute_path, path) && return complete(path)
  ismatch(relative_path, path) && return complete(joinpath(base, path))
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
  path = subpath ≡ nothing ? package : joinpath(package, subpath)
  complete(path, pkgname)
end

function resolve_github(url::AbstractString)
  user,reponame,tag = match(gh_shorthand, url).captures
  localpath = joinpath(repos, user, reponame)
  repo = if isdir(localpath)
    LibGit2.GitRepo(localpath)
  else
    LibGit2.clone("https://github.com/$user/$reponame.git", localpath)
  end

  # checkout the specified tag/branch/commit
  if tag ≡ nothing
    LibGit2.checkout!(repo, LibGit2.revparseid(repo, "master") |> string)
  elseif ismatch(semver_regex, tag)
    tags = LibGit2.tag_list(repo)
    v,idx = findmax(semver_query(tag), VersionNumber(t) for t in tags)
    @assert idx > 0 "$user/$reponame has no tag matching $tag. Try again after running Kip.update()"
    LibGit2.checkout!(repo, LibGit2.revparseid(repo, tags[idx]) |> string)
  else
    LibGit2.checkout!(repo, LibGit2.revparseid(repo, tag) |> string)
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
The directory the application is located in. If your running `julia /some/file.jl`
then `entry`  should be set to `"/some"`

Can be set using `Kip.eval(:(entry = "/some/path"))`
"""

function __init__()
  # If we are running a file and not at the REPL
  if !isinteractive() && !isempty(ARGS)
    # set Kip.entry to the dirname of the file being run
    global entry = dirname(realpath(joinpath(pwd(), ARGS[1])))
  else
    global entry = pwd()
  end
end

"""
Get the directory the current file is stored in. If your in the REPL
it will just return `entry`
"""
macro dirname()
  :(current_module() === Main ? entry : Base.source_dir())
end

##
# Require `path` relative to the current module
#
function require(path::AbstractString; locals...)
  require(path, @dirname; locals...)
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
    name = Symbol(split(replace(path, Pkg.dir(), ""), '/', keep=false)[1])
    return eval(:(import $name; $name))
  end

  mod = Module(name)

  eval(mod, quote
    using Kip
    eval(x) = Core.eval($name, x)
    eval(m, x) = Core.eval(m, x)
    $([:(const $k = $v) for (k,v) in locals]...)
    include($path)
  end)

  # unpack the submodule if thats all thats in it. For unregistered native modules
  locals = filter(n -> n != :eval && n != Symbol("#eval"), names(mod, true))
  if length(locals) == 1 && isa(getfield(mod, locals[1]), Module)
    return getfield(mod, locals[1])
  end

  return mod
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
macro require(path, names...)
  # @require "path" => name ...
  if isa(path, Expr)
    path,name = path.args
    name = esc(name)
  # @require "path" ...
  else
    isempty(names) && return :(require($path))
    name = Symbol(path)
  end
  ast = :(const $name = require($path))
  isempty(names) && return ast
  ast = :(begin $ast end)
  names = collect(Any, names) # make array
  for n in names
    if isa(n, Expr)
      if n.head == :macrocall
        # support importing macros
        append!(names, n.args)
      elseif n.head == :...
        # import all exported symbols
        # TODO: defer require until runtime
        m = require(path)
        mn = module_name(m)
        append!(names, filter(n -> n != mn, Base.names(m)))
      else
        # support renaming variables as they are imported
        @assert n.head == Symbol("=>")
        push!(ast.args, :(const $(esc(n.args[2])) = $name.$(n.args[1])))
      end
    else
      @assert isa(n, Symbol)
      push!(ast.args, :(const $(esc(n)) = $name.$n))
    end
  end
  push!(ast.args, name)
  ast
end

export @require, @dirname

end # end of module
