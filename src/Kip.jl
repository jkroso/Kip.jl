__precompile__()

module Kip # start of module

import Requests
import JSON
include("./deps.jl")

const gh_shorthand = r"
  ^github.com/  # all github paths start the same way
  ([\w-.]+)     # username
  /
  ([\w-.]+)     # repo
  (?:@([^/]+))? # commit, tag, branch, or semver query (defaults to latest commit)
  (?:/(.+))?    # path to the module inside the repo (optional)
  $
"x
const relative_path = r"^\.{1,2}"

function GET(url; meta=Dict())
  response = Requests.get(encode(url); headers=meta)
  if response.status >= 400
    error("status $(response.status) for $(encode(url))")
  else
    response.data
  end
end

parseJSON(data::Vector{UInt8}) = JSON.parse(bytestring(data))

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
function complete(path::AbstractString)
  for p in (path, path * ".jl", joinpath(path, "main.jl"))
    isfile(p) && return p
  end

  # check "src/$(module_name).jl". A preexisting Julia convention
  legacy = joinpath(path, "src", reponame(path))
  # ensure the path ends in a ".jl"
  legacy = replace(legacy, r"(\.jl)?$", ".jl")
  ispath(legacy) && return legacy

  error("$path can not be completed to a file")
end

##
# Take a guess at what the module must be called
#
function reponame(path)
  m = match(r"github\.com/[^/]+/([^/]+)", path)
  m == nothing || return m[1]
  return basename(path)
end

const cached = Set{AbstractString}()

##
# Download a package and return its local location
#
function download(url::AbstractString)
  name = joinpath(tempdir(), replace(url, r"^.*://", ""))
  name in cached && return name
  if !ispath(name)
    mkpath(name)
    stdin, proc = open(`tar --strip-components 1 -xmpf - -C $name`, "w")
    write(stdin, GET(url))
    close(stdin)
    wait(proc)
  end
  push!(cached, name)
  return name
end

##
# Resolve a require call to an absolute file path
#
function resolve(path::AbstractString, base::AbstractString)
  path[1] == '/' && return complete(path)
  ismatch(relative_path, path) && return complete(joinpath(base, path))
  @assert ismatch(gh_shorthand, path) "unable to resolve '$path'"
  url,path = resolve_gh(path)
  package = download(url)
  path = isempty(path) ? package : joinpath(package, path)
  build(package)
  complete(path)
end

function resolve_gh(dep::AbstractString)
  user,repo,tag,path = match(gh_shorthand, dep).captures
  if tag ≡ nothing
    tag = latest_gh_commit(user, repo)[1:7]
  elseif ismatch(semver_regex, tag)
    tag = resolve_gh_tag(user, repo, tag)
  end
  ("http://github.com/$user/$repo/tarball/$tag", path ≡ nothing ? "" : path)
end

function latest_gh_commit(user::AbstractString, repo::AbstractString)
  url = "https://api.github.com/repos/$user/$repo/git/refs/heads/master"
  parseJSON(GET(url))["object"]["sha"]
end

function resolve_gh_tag(user, repo, tag)
  tags = GET("https://api.github.com/repos/$user/$repo/tags") |> parseJSON
  findmax(semver_query(tag), VersionNumber[t["name"] for t in tags])
end

# Can be emptied with `empty!`
const cache = Dict{AbstractString,Module}()

# Can be set using `Kip.eval`
entry = pwd()

macro dirname()
  :(current_module() === Main ? entry : dirname(string(current_module())))
end

##
# Require `path` relative to the current module
#
function require(path::AbstractString; locals...)
  require(path, @dirname; locals...)
end

##
# Require `path` relative to `base`
#
function require(path::AbstractString, base::AbstractString; locals...)
  name = realpath(resolve(path, base))
  haskey(cache, name) && return cache[name]
  cache[name] = eval_module(name; locals...)
end

const native_module_path = r"github\.com/([^/]+)/([^/.]+)(?:\.jl)?/tarball/[^/]+/src/([^/]+)\.jl"

function eval_module(path::AbstractString; locals...)
  sym = symbol(path)
  mod = Module(sym)

  # is a registered module
  m = match(native_module_path, path)
  if m != nothing && m[2] == m[3] && ispath(Pkg.dir("METADATA", m[2]))
    url = readall(Pkg.dir("METADATA", m[2], "url"))
    user,name = match(r"github.com/([^/]+)/([^/.]+)", url).captures
    if user == m[1] && name == m[2]
      ispath(Pkg.dir(name)) || Pkg.add(name)
      return eval(:(import $(symbol(name)); $(symbol(name))))
    end
  end

  eval(mod, quote
    using Kip
    eval(x) = Core.eval($sym, x)
    eval(m, x) = Core.eval(m, x)
    $([:(const $k = $v) for (k,v) in locals]...)
    include($path)
  end)

  # unpack the submodule if thats all thats in it. For legacy support
  locals = filter(n -> n != sym && n != :eval, names(mod, true))
  if length(locals) == 1 && isa(mod.(locals[1]), Module)
    return mod.(locals[1])
  end

  return mod
end

macro require(path, names...)
  if isa(path, Expr)
    path,name = path.args
    name = esc(name)
  else
    isempty(names) && return :(require($path))
    name = symbol(path)
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
      else
        # support renaming variables as they are imported
        @assert n.head == symbol("=>")
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
