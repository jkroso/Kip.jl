@require "SemverQuery" semver_query regex => semver_regex
@require "parse-json" parse => parseJSON
@require "prospects" mapcat get_in

const gh_shorthand = r"^([\w-.]+)/([\w-.]+)(?:@([^:]+))?(?::(.+))?$"
const relative_path = r"^\.{1,2}([^.]|$)"
const types = Dict("jl" => MIME("application/julia"))

mime_type(name) = types[split(name, '.')[end]]

##
# Install all dependencies of a module recursively and symlink
# them into a local dependencies folder
#
function install(name::AbstractString)
  dir = dirname(name)
  for ref in dependencies(name)
    if ismatch(relative_path, ref)
      joinpath(dir, ref) |> realpath
    else
      url,path = resolve(ref)
      cached_name = cache(url)
      link_name = joinpath(dir, "dependencies", ref)
      mkpath(dirname(link_name))
      islink(link_name) && rm(link_name)
      symlink(cached_name, link_name)
      isempty(path) ? cached_name : joinpath(cached_name, path)
    end |> complete |> install
  end
  # Run Julia's conventional install hook
  deps = joinpath(dir, "deps")
  isdir(deps) && cd(deps) do
    run(`julia build.jl`)
  end
  nothing
end

##
# Try some sensible defaults if `path` doesn't already refer to
# a file
#
function complete(path::AbstractString)
  for p in (path, path * ".jl", joinpath(path, "index.jl"))
    isfile(p) && return p
  end
  error("$path can not be completed to a file")
end

test("install") do
  @test install("example/index.jl") ≡ nothing
  @test isdir("example/dependencies/jkroso/emitter.jl")
end

const cache_dir = joinpath(homedir(), ".julia", "kip")
const cached = Set{AbstractString}()

##
# Translate a `url` into a connonacal local file system path
# and if it has not yet been installed, download it
#
function cache(url::AbstractString)
  name = joinpath(cache_dir, replace(url, r"^.*://", ""))
  name in cached && return name
  if !ispath(name)
    mkpath(name)
    (`curl -sL $url`
      |> s -> pipeline(s, `gzip -dc`)
      |> s -> pipeline(s, `tar --strip-components 1 -xmpf - -C $name`)
      |> run)
  end
  push!(cached, name)
  return name
end

test("cache") do
  path = cache("http://github.com/jkroso/Jest.jl/tarball/df8f756")
  @test ispath(joinpath(path, "index.jl"))
end

##
# Find the dependencies of a module
#
dependencies(path::AbstractString) = dependencies(mime_type(path), readall(path), path)
dependencies(::MIME"application/julia", src::AbstractString, name::AbstractString) = begin
  unique(requires(parse("begin\n$src\nend")))
end

requires(e) = ()
requires(e::Expr) = begin
  args = e.args
  if e.head ≡ :macrocall && args[1] == symbol("@require")
    tuple(args[2])
  else
    mapcat(requires, args)
  end
end

@test dependencies("index.jl") == ["SemverQuery","parse-json","prospects"]

function resolve(dep::AbstractString)
  ismatch(gh_shorthand, dep) && return resolve_gh(dep)
  error("unable to resolve '$dep'")
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

@test resolve("jkroso/Jest.jl") == ("http://github.com/jkroso/Jest.jl/tarball/d3fb269","")

function latest_gh_commit(user::AbstractString, repo::AbstractString)
  (`curl -sL https://api.github.com/repos/$user/$repo/git/refs/heads/master`
    |> readall
    |> parseJSON
    |> data -> get_in(data, ("object", "sha")))
end

@test latest_gh_commit("jkroso", "Jest.jl")[1:7] == "d3fb269"

function resolve_gh_tag(user, repo, tag)
  tags = `curl -sL https://api.github.com/repos/$user/$repo/tags` |> readall |> parseJSON
  findmax(semver_query(tag), VersionNumber[t["name"] for t in tags])
end

@test resolve_gh_tag("jkroso", "Jest.jl", "0") == v"0.0.3"
