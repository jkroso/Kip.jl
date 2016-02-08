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
  name = joinpath(homedir(), ".kip", replace(url, r"^.*://", ""))
  name in cached && return name
  if !ispath(name)
    mkpath(name)
    stdin, proc = open(`tar --strip-components 1 -xmpzf - -C $name`, "w")
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
  m = match(gh_shorthand, path)
  @assert m != nothing  "unable to resolve '$path'"
  username, reponame = m.captures
  pkgname = replace(reponame, r"\.jl$", "")
  if isregistered(username, pkgname)
    ispath(Pkg.dir(pkgname)) || Pkg.add(pkgname)
    return Pkg.dir(pkgname) |> complete
  end
  url,path = resolve_gh(path)
  package = download(url)
  path = isempty(path) ? package : joinpath(package, path)
  build(package)
  complete(path)
end

function isregistered(username::AbstractString, pkgname::AbstractString)
  # same name as a registered module
  ispath(Pkg.dir("METADATA", pkgname)) || return false
  url = readall(Pkg.dir("METADATA", pkgname, "url"))
  m = match(r"github.com/([^/]+)/([^/.]+)", url).captures
  # is a registered module
  username == m[1] && pkgname == m[2]
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

const username = get(ENV, "GITHUB_USERNAME", "")
const password = get(ENV, "GITHUB_PASSWORD", "")
const headers = Dict{ASCIIString,ASCIIString}()

if !isempty(username) && !isempty(password)
  headers["Authorization"] = "Basic " * base64encode(string(username, ':', password))
end

function latest_gh_commit(user::AbstractString, repo::AbstractString)
  url = "https://api.github.com/repos/$user/$repo/git/refs/heads/master"
  parseJSON(GET(url; meta=headers))["object"]["sha"]
end

function resolve_gh_tag(user, repo, tag)
  tags = GET("https://api.github.com/repos/$user/$repo/tags"; meta=headers) |> parseJSON
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

function eval_module(path::AbstractString; locals...)
  sym = symbol(path)
  mod = Module(sym)

  # if installed in native location then load it using native system
  if startswith(path, Pkg.dir())
    name = split(replace(path, Pkg.dir(), ""), '/', keep=false)[1]
    return eval(:(import $(symbol(name)); $(symbol(name))))
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
