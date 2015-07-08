@require "SemverQuery" semver_query regex => semver_regex
@require "parse-json" parse => parseJSON
@require "prospects" mapcat get_in

const types = ["jl" => MIME("application/julia")]

mime_type(name) = types[split(name, '.')[end]]

##
# Install all dependencies of a module recursively and symlink
# them into a local dependencies folder
#
function install(name::String)
  dir = dirname(name)
  for ref in dependencies(name)
    url,path = resolve(ref)
    cached_name = cache(url)
    link_name = joinpath(dir, "dependencies", ref)
    mkpath(dirname(link_name))
    islink(link_name) && rm(link_name)
    symlink(cached_name, link_name)
    install(joinpath(cached_name, isempty(path) ? "index.jl" : path))
  end
end

test("install") do
  @test install("example/index.jl") ≡ nothing
  @test isdir("example/dependencies/jkroso/emitter.jl")
end

const cache_dir = joinpath(homedir(), ".julia", "kip")
const cached = Set{String}()

##
# Translate a `url` into a connonacal local file system path
# and if it has not yet been installed, download it
#
function cache(url::String)
  name = joinpath(cache_dir, replace(url, r"^.*://", ""))
  name in cached && return name
  if !ispath(name)
    mkpath(name)
    (`curl -sL $url`
      |> `gzip -dc`
      |> `tar --strip-components 1 -xmpf - -C $name`
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
dependencies(path::String) = dependencies(mime_type(path), readall(path), path)
dependencies(::MIME"application/julia", src::String, name::String) = begin
  ast = macroexpand(parse("begin\n$src\nend"))
  unique(requires(ast))
end

requires(e) = ()
requires(e::Expr) = begin
  args = e.args
  if e.head ≡ :call && length(args) ≡ 2 && args[1] == Expr(:., Requirer, QuoteNode(:require))
    (args[2],)
  else
    mapcat(requires, args)
  end
end

@test dependencies(pwd() * "/index.jl") == {"SemverQuery","parse-json","prospects"}

const gh_shorthand = r"^([\w-.]+)/([\w-.]+)(?:@([^:]+))?(?::(.+))?$"

function resolve(dep::String)
  ismatch(gh_shorthand, dep) && return resolve_gh(dep)
  error("unable to resolve '$dep'")
end

function resolve_gh(dep::String)
  user,repo,tag,path = match(gh_shorthand, dep).captures
  if tag ≡ nothing
    tag = latest_gh_commit(user, repo)[1:7]
  elseif ismatch(semver_regex, tag)
    tag = resolve_gh_tag(user, repo, tag)
  end
  ("http://github.com/$user/$repo/tarball/$tag", path ≡ nothing ? "" : path)
end

@test resolve("jkroso/Jest.jl") == ("http://github.com/jkroso/Jest.jl/tarball/df8f756","")

function latest_gh_commit(user::String, repo::String)
  (`curl -sL https://api.github.com/repos/$user/$repo/git/refs/heads/master`
    |> readall
    |> parseJSON
    |> data -> get_in(data, ("object", "sha")))
end

@test latest_gh_commit("jkroso", "Jest.jl")[1:7] == "df8f756"

function resolve_gh_tag(user, repo, tag)
  tags = `curl -sL https://api.github.com/repos/$user/$repo/tags` |> readall |> parseJSON
  findmax(semver_query(tag), VersionNumber[t["name"] for t in tags])
end

@test resolve_gh_tag("jkroso", "Jest.jl", "0") == v"0.0.3"
