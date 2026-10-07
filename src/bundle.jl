##
# Kip.bundle: write a script and every Kip file it @uses into one Julia file,
# so it runs without Kip, Git or LibGit2
#

"""
    bundle(entry, dir; project, name, includes=[], files=[], precompile=true) -> String

Write the script `entry` and every Kip file it `@use`s, directly or through
other files, into `dir`. Returns the path of `dir/bundle.jl`.

`dir` gets these files:

- `bundle.jl` holds the source of every file, each in its own module. Run it
  with `julia bundle.jl [arguments]`, as you would run `entry`.
- `files/` holds a copy of every file the program may read from where its code
  is (see below). The bundled code runs as if it were these copies.
- `Project.toml` and `Manifest.toml` list the registered packages the files
  use, at the versions in `project`.
- `juliac.jl` is the file to give JuliaC to build an app from the bundle.

Each `@use` is resolved now, so the bundle has no need for Kip when it runs.
It includes a small stand-in for Kip instead, which only looks modules up.

`dir` holds everything the program reads from its code's folders, so it can be
copied to another machine, even one with another OS, and run or built there.
`@__DIR__` in a bundled file is the folder of its copy in `files/`. These are
copied:

- every file the bundle holds, and every file the program `include`s;
- each file or folder a file names by a path from its own folder, written in
  the source: `joinpath(@__DIR__, "data.json")`, `"\$(@__DIR__)/data.json"`,
  `@dirname`, or `dirname(@__FILE__)`;
- the whole folder of each package that a `@use` fetched from GitHub, as Kip
  would have it on disk, but without hidden files such as `.git`;
- each file or folder in `files`.

The bundle is also a package. Julia compiles it the first time it runs, and
loads it from that compile cache after. Pass `precompile=false` if the files
must run their top-level code each time the bundle starts.

Keywords:

- `project`: the folder of the Julia project that has the registered packages
  the files use. By default it is the project Kip installs packages into.
- `name`: the package name of the bundle. By default it comes from `entry`,
  e.g. `app.jl` gives `AppBundle`.
- `includes`: files, or folders of `.jl` files, that the program finds and
  loads with `include` while it runs, such as plugins. These files stay where
  they are, but the bundle holds every file they `@use`. An `include` whose
  path is in the source needs no entry here: the bundler follows it itself.
- `files`: other files or folders the program reads from where its code is,
  by paths the bundler can't see in the source. A relative path is from the
  folder of `entry`.

A module that only included files use waits to start (run its `__init__`)
until one of them first `@use`s it, as under Kip. This covers files in
`includes` and files that a function includes. Other modules start when the
bundle loads.
"""
function bundle(entry::AbstractString, dir::AbstractString;
                project::AbstractString=default_project(),
                name::AbstractString=bundle_name(entry),
                includes=String[],
                files=String[],
                precompile::Bool=true)
  entry = realpath(first(complete(entry)))
  deps, lazy, table, unbundled, packages = bundle_graph(entry, included_files(includes))
  pkgs = bundle_packages([deps; unbundled], table, project)
  mkpath(dir)
  extra = map(f -> realpath(isabspath(f) ? f : joinpath(dirname(entry), f)), files)
  root = copy_files(joinpath(dir, "files"), entry, [entry; deps; unbundled], packages, extra)
  write(joinpath(dir, "bundle.jl"), bundle_source(entry, deps, lazy, table, name, precompile, root))
  write(joinpath(dir, "juliac.jl"), """
    # JuliaC compiles this file into an app. It loads the bundle, a package with
    # a compile cache, and runs the entry script, which defines `main`.
    using $name
    $name.run(Main)
    """)
  write_project(dir, name, entry, pkgs, project)
  joinpath(dir, "bundle.jl")
end

"The project Kip installs `@use`d packages into: the folder Julia started in, or else the active project"
default_project() =
  isfile(joinpath(initial_pwd, "Project.toml")) ? initial_pwd :
  dirname(something(Base.active_project(), joinpath(initial_pwd, "Project.toml")))

"A package name for the bundle of `entry`, e.g. app.jl → AppBundle and 26_finder.jl → Bundle26Finder"
function bundle_name(entry::AbstractString)
  # abspath: the name of a main.jl comes from its folder
  name = join(uppercasefirst.(split(pkgname(abspath(entry)), r"[^A-Za-z0-9]+", keepempty=false)))
  isempty(name) || isdigit(first(name)) ? "Bundle" * name : name * "Bundle"
end

"The files `includes` names: each file, and the `.jl` files in each folder"
included_files(includes) =
  map(realpath, mapreduce(vcat, includes; init=String[]) do p
    isdir(p) ? filter(endswith(".jl"), readdir(p, join=true)) :
    isfile(p) ? [p] :
    error("Kip.bundle: $p in `includes` isn't a file or a folder")
  end)

"""
Every Kip file that `entry` and the files in `extra` depend on, in load order.
Then which of those files only the files in `extra` need: their modules wait
to start until the program first asks for them. Then where each `@use` path in
each file leads: to a file, or to the PkgId of a GitHub repo that is a normal
Julia package. Then the files read but not bundled: `entry`, the files in
`extra`, and the files any of these load with an `include` whose path is in the
source. The program loads those itself. Last, the folder of each package a
`@use` fetched from GitHub.
"""
function bundle_graph(entry::String, extra::Vector{String}=String[])
  order = String[]
  table = Dict{Tuple{String,String},Union{String,Base.PkgId}}()
  packages = Set{String}()
  state = Dict{String,Symbol}()
  # Files in `extra` the program includes itself, so the bundle doesn't hold them
  unbundled = Set{String}()
  function visit(file; bundled=true)
    s = get(state, file, nothing)
    if s === :done
      bundled && file == entry && error("Kip.bundle: a file @uses $entry, the script being bundled")
      # A file in `extra` that a bundled file @uses must be bundled after all
      bundled && file in unbundled && (delete!(unbundled, file); push!(order, file))
      return
    end
    s === :visiting && error("Kip.bundle: $file @uses itself through other files")
    state[file] = :visiting
    ast = Meta.parseall(read(file, String); filename=file)
    for path in unique(use_paths!(String[], ast))
      target = locate(path, dirname(file), packages)
      table[(file, path)] = target
      target isa String && visit(target)
    end
    # The file `include`s these into itself, so they stay on disk like `extra`.
    # A function includes its files when it runs, so those wait like `extra`.
    now, when_run = include_paths!((String[], String[]), ast, dirname(file))
    foreach(f -> visit(f, bundled=false), now)
    append!(later, when_run)
    state[file] = :done
    bundled ? push!(order, file) : push!(unbundled, file)
  end
  later = String[]
  visit(entry, bundled=false)
  eager = length(order)
  append!(later, extra)
  while !isempty(later)
    visit(popfirst!(later), bundled=false)
  end
  order, Set(order[eager+1:end]), table, collect(unbundled), collect(packages)
end

"""
The real path of each file that an `include` call in `ex`, a file in the
folder `dir`, loads, when the source names the path: a string, or `joinpath`
of strings and `@__DIR__` or `@dirname`. Returns two lists: the files included
as the file loads, and the files included inside a function, when it runs.
Other paths are known only when the program runs, so those files need naming
in `includes`.
"""
function include_paths!(found::Tuple{Vector{String},Vector{String}}, ex, dir::AbstractString, in_function::Bool=false)
  ex isa Expr && ex.head !== :quote || return found
  in_function |= is_definition(ex)
  if ex.head === :call && ex.args[1] === :include && length(ex.args) in (2, 3)
    p = written_path(ex.args[end], dir)
    p === nothing || (p = normpath(dir, p); isfile(p) && push!(found[in_function + 1], realpath(p)))
  end
  foreach(a -> include_paths!(found, a, dir, in_function), ex.args)
  found
end

"A function, closure or macro, whose body runs later, not as its file loads"
is_definition(ex) =
  Meta.isexpr(ex, (:function, :macro, :->, :do)) ||
  (Meta.isexpr(ex, :(=)) && Meta.isexpr(ex.args[1], (:call, :where)))

written_path(ex, dir) =
  ex isa String ? ex :
  Meta.isexpr(ex, :macrocall) && ex.args[1] in (Symbol("@__DIR__"), Symbol("@dirname")) ? dir :
  Meta.isexpr(ex, :call) && ex.args[1] === :joinpath && length(ex.args) > 1 ? begin
    parts = map(a -> written_path(a, dir), ex.args[2:end])
    any(isnothing, parts) ? nothing : joinpath(parts...)
  end :
  nothing

"""
Copy into the folder `dest` every file the bundled program may read from where
its code is: the files in `sources`, the files and folders they name by a path
from their own folder (see `data_paths!`), each package folder in `packages`,
and the files and folders in `extra`. The copies keep their places relative to
each other, under the deepest folder that holds them all. Returns that folder.
"""
function copy_files(dest::AbstractString, entry::String, sources, packages, extra)
  paths = Set{String}(sources)
  found = Set{String}(extra)
  for f in sources
    data_paths!(found, Meta.parseall(read(f, String); filename=f), dirname(f))
  end
  for p in found
    if isdir(p)
      # `joinpath(@__DIR__, "..")` would copy the whole program and more
      startswith(entry, rstrip(p, ('/', '\\')) * Base.Filesystem.path_separator) && continue
      tree_files!(paths, p)
    elseif isfile(p)
      push!(paths, realpath(p))
    end
  end
  foreach(p -> tree_files!(paths, p), packages)
  root = common_dir(paths)
  rm(dest; recursive=true, force=true)
  for p in paths
    copy = joinpath(dest, relpath(p, root))
    mkpath(dirname(copy))
    cp(p, copy; force=true, follow_symlinks=true)
  end
  root
end

"Every file under the folder `dir`, leaving out hidden files and folders such as `.git`"
function tree_files!(out::Set{String}, dir::AbstractString)
  for name in readdir(dir)
    startswith(name, '.') && continue
    p = joinpath(dir, name)
    isdir(p) ? tree_files!(out, p) : isfile(p) && push!(out, realpath(p))
  end
  out
end

"The deepest folder that holds every file in `paths`"
function common_dir(paths)
  parts = [splitpath(dirname(p)) for p in paths]
  k = 0
  while all(ps -> length(ps) > k && ps[k+1] == parts[1][k+1], parts)
    k += 1
  end
  k > 0 || error("Kip.bundle: the files have no folder in common: $(join(paths, ", "))")
  joinpath(parts[1][1:k]...)
end

"`path`, a file below the folder `root`, as `root` names it in a bundle: always with `/`"
bundle_path(path::AbstractString, root::AbstractString) = join(splitpath(relpath(path, root)), '/')

"""
Each file or folder that `ex`, the code of a file in the folder `dir`, names by
a path from that folder: `joinpath(@__DIR__, "a", "b")`, `"\$(@__DIR__)/a"`,
`@__DIR__() * "/a"`, with `@dirname` or `dirname(@__FILE__)` for `@__DIR__`.
Only paths that exist go in `found`.
"""
function data_paths!(found::Set{String}, ex, dir::AbstractString)
  ex isa Expr && ex.head !== :quote || return found
  p = dir_path(ex, dir)
  p === nothing || p == dir || (p = normpath(p); ispath(p) && push!(found, realpath(p)))
  foreach(a -> data_paths!(found, a, dir), ex.args)
  found
end

"The path `ex` builds from `dir`, the folder of its file, when the source names it; otherwise nothing"
function dir_path(ex, dir)
  is_dir_expr(ex) && return dir
  Meta.isexpr(ex, :call) && length(ex.args) >= 3 || Meta.isexpr(ex, :string) || return nothing
  args = ex.head === :string ? ex.args : ex.args[2:end]
  ex.head === :call && ex.args[1] ∉ (:joinpath, :*) && return nothing
  length(args) >= 2 && all(a -> a isa String, args[2:end]) || return nothing
  base = dir_path(args[1], dir)
  base === nothing && return nothing
  ex.head === :call && ex.args[1] === :joinpath ? joinpath(base, args[2:end]...) : base * join(args[2:end])
end

"`@__DIR__`, `@dirname` or `dirname(@__FILE__)`"
is_dir_expr(ex) =
  (Meta.isexpr(ex, :macrocall) && ex.args[1] in (Symbol("@__DIR__"), Symbol("@dirname"))) ||
  (Meta.isexpr(ex, :call, 2) && ex.args[1] === :dirname &&
   Meta.isexpr(ex.args[2], :macrocall) && ex.args[2].args[1] === Symbol("@__FILE__"))

is_use(ex) = ex === Symbol("@use") || ex == Expr(:., :Kip, QuoteNode(Symbol("@use")))
ispair(ex) = Meta.isexpr(ex, :call, 3) && ex.args[1] === :(=>)

"(path, alias, splatall) for a path form of @use, or nothing for a package form"
function pathform(first)
  first isa String && return (first, nothing, false)
  ispair(first) && first.args[2] isa String && return (first.args[2], first.args[3], false)
  Meta.isexpr(first, :..., 1) && first.args[1] isa String && return (first.args[1], nothing, true)
  nothing
end

"Every path that a `@use` call anywhere in `ex` looks up"
function use_paths!(out::Vector{String}, ex)
  ex isa Expr || return out
  if ex.head === :macrocall && is_use(ex.args[1])
    use_call_paths!(out, filter(a -> !(a isa LineNumberNode), ex.args[2:end]))
  end
  foreach(a -> use_paths!(out, a), ex.args)
  out
end

"`normpath(a, b)` for a @use path, with `/` between its parts on every OS, as the stand-in joins them"
use_join(a::AbstractString, b::AbstractString) =
  Sys.iswindows() ? replace(normpath(a, b), '\\' => '/') : normpath(a, b)

"The paths the `@use` call with arguments `args` looks up, built the way the macro builds them"
function use_call_paths!(out::Vector{String}, args)
  isempty(args) && return out
  form = pathform(args[1])
  form === nothing && return out # a registered package
  path, alias, splatall = form
  names = collect(Any, args[2:end])
  i = 0
  while i < length(names)
    n = names[i += 1]
    Meta.isexpr(n, :macrocall) && append!(names, n.args)
  end
  # Like the macro, a @use of nothing but [bracketed] files doesn't load `path` itself
  alias === nothing && !splatall && !isempty(names) && all(inbrackets, names) || push!(out, path)
  for n in filter(inbrackets, names), row in tovcat(n).args
    relpath, rest = row.args[1], row.args[2:end]
    sub = ispair(relpath) ? :($(use_join(path, relpath.args[2])) => $(relpath.args[3])) : use_join(path, relpath)
    use_call_paths!(out, Any[sub, rest...])
  end
  out
end

"""
Where the `@use` path `path`, in a file in the folder `base`, leads: a file, or
the PkgId of a GitHub repo that is a normal Julia package. Mirrors `require`,
but it never loads anything. The folder of a GitHub repo it leads into goes in
`packages`.
"""
function locate(path::AbstractString, base::AbstractString, packages::Set{String}=Set{String}())
  startswith(path, "~/") && (path = homedir() * path[2:end])
  occursin(absolute_path, path) && return realpath(first(complete(path)))
  occursin(relative_path, path) && return realpath(first(complete(normpath(base, path))))
  m = match(gh_shorthand, path)
  m === nothing && error("Kip.bundle: unable to resolve '$path' in $base")
  username, reponame, tag, subpath = m.captures
  pkgname = splitext(reponame)[1]
  repo = getrepo(username, reponame)
  if is_pkg3_pkg(LibGit2.path(repo))
    # Kip installs these into the project of the folder that @uses them
    is_installed(base, pkgname) || error("Kip.bundle: $pkgname isn't installed in $base. Run the script with Kip once to install it.")
    uuid = TOML.parsefile(joinpath(base, "Project.toml"))["deps"][pkgname]
    return Base.PkgId(Base.UUID(uuid), pkgname)
  end
  package = checkout_repo(repo, username, reponame, tag)
  push!(packages, realpath(package))
  file = isnothing(subpath) ? first(complete(package, pkgname)) : first(complete(joinpath(package, subpath)))
  realpath(file)
end

"""
The registered packages that `files` load, as name => UUID. A package's UUID
comes from `project`, or else from where Kip itself would find the package.
"""
function bundle_packages(files, table, project::AbstractString)
  names = Set{String}()
  for f in files
    package_names!(names, Meta.parseall(read(f, String); filename=f))
  end
  pkgs = Dict(n => package_uuid(n, project) for n in names if n ∉ ("Base", "Core", "Main", "Kip"))
  for target in values(table)
    target isa Base.PkgId && (pkgs[target.name] = string(target.uuid))
  end
  pkgs
end

"Names of the packages that `using`, `import` and `@use PkgName` statements in `ex` load"
function package_names!(out::Set{String}, ex)
  # Code in a quote runs later, if at all, so it doesn't load packages when the file loads
  ex isa Expr && ex.head !== :quote || return out
  if ex.head in (:using, :import)
    for a in ex.args
      Meta.isexpr(a, :(:)) && (a = a.args[1])
      Meta.isexpr(a, :as) && (a = a.args[1])
      # `using .Sub` and `import ..Parent` name modules, not packages
      Meta.isexpr(a, :.) && a.args[1] isa Symbol && a.args[1] !== :. && push!(out, String(a.args[1]))
    end
  elseif ex.head === :macrocall && is_use(ex.args[1])
    args = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
    if !isempty(args) && pathform(args[1]) === nothing
      pkg = leftmost(args[1])
      pkg isa Symbol && push!(out, String(pkg))
    end
  end
  foreach(a -> package_names!(out, a), ex.args)
  out
end

"The package in a `@use` package form: `Pkg`, `Pkg: a, b`, `Pkg...`, `Pkg.Sub`, …"
leftmost(ex) =
  ex isa Symbol ? ex :
  ex isa Expr && length(ex.args) >= 2 && ex.head === :call ? leftmost(ex.args[2]) :
  ex isa Expr && !isempty(ex.args) ? leftmost(ex.args[1]) :
  nothing

function package_uuid(name::String, project::AbstractString)
  file = joinpath(project, "Project.toml")
  if isfile(file)
    uuid = get(get(TOML.parsefile(file), "deps", empty_deps), name, nothing)
    uuid === nothing || return uuid
  end
  file = joinpath(project, "Manifest.toml")
  if isfile(file)
    manifest = TOML.parsefile(file)
    # Manifest format 2 keeps its packages under [deps], format 1 at the top
    entries = get(get(manifest, "deps", manifest), name, nothing)
    entries isa Vector && return entries[1]["uuid"]
  end
  # Then where Kip finds it when it loads a file: a standard library, a package
  # this process has loaded (such as Kip's own MacroTools), or a registry
  uuid = find_pkg_uuid(name)
  uuid === nothing || return uuid
  error("""Kip.bundle: the files use the package $name, but $project doesn't have it. \
           Add it to that project, or pass `project` the folder of a project that has it.""")
end

"A UUID for the bundle of `entry`, the same each time it's bundled"
bundle_uuid(entry::AbstractString) = deterministic_uuid(source_hash("Kip.bundle " * entry))

"""
A module name for each bundled file. It's the name Kip gives the file (see
`module_name`), made unique: two modules in one package can't share a name.
Julia saves a package with a duplicate silently, then crashes as it loads it.
"""
function module_names(files, owner::AbstractString)
  used = Dict{Symbol,Int}()
  map(files) do f
    name = module_name(f; owner=owner_name(f, owner))
    n = used[name] = get(used, name, 0) + 1
    n == 1 ? name : Symbol(name, '~', n)
  end
end

raw_string(s::AbstractString) = string("raw\"", Base.escape_raw_string(s), "\"")

function bundle_source(entry::String, deps::Vector{String}, lazy::Set{String}, table, name::AbstractString, precompile::Bool, root::AbstractString)
  index = Dict(f => i for (i, f) in enumerate(deps))
  # A file's path in the bundle: its copy in files/, wherever the bundle is
  here(f) = "Kip.here($(repr(bundle_path(f, root))))"
  io = IOBuffer()
  print(io, """
    # Built by Kip.bundle from $entry
    # It holds $(length(deps) + 1) files. Run it with `julia bundle.jl [arguments]`.
    if @__MODULE__() === Main
      # Load this file as a package, so Julia uses its compile cache, then run
      # the entry script. Exit here: the rest of this file defines that package.
      pushfirst!(LOAD_PATH, @__DIR__)
      using $name
      exit($name.script())
    end

    module $name
    """)
  precompile || println(io, "__precompile__(false)")
  println(io, read(joinpath(@__DIR__, "standin.jl"), String))
  println(io, "# The copies of the files the bundle was made from, which the bundled code runs as")
  println(io, "Kip.root[] = realpath(joinpath(@__DIR__, \"files\"))\n")
  println(io, "# Where each @use leads: (file, path) => index of a bundled module, or a package")
  println(io, "for (k, v) in Pair{Tuple{String,String},Union{Int,Base.PkgId}}[")
  for ((file, path), target) in sort!(collect(table), by=first)
    v = target isa String ? string(index[target]) :
        "Base.PkgId(Base.UUID($(repr(string(target.uuid)))), $(repr(target.name)))"
    println(io, "    ($(here(file)), $(repr(path))) => $v,")
  end
  println(io, "  ]\n  Kip.resolved!(k..., v)\nend")
  println(io, "\n# Each bundled file: its module's name, its path, its source, and whether it's lazy")
  println(io, "Kip.bundle[] = @__MODULE__")
  for (file, mod) in zip(deps, module_names(deps, basename(dirname(entry))))
    println(io, "Kip.add_source!($(repr(mod)), $(here(file)), ", raw_string(read(file, String)), ", $(file in lazy))")
  end
  println(io, "\n# Make each file's module, in load order")
  println(io, "foreach(Kip.define, eachindex(Kip.sources))")
  print(io, """

    # The entry script. `run` evaluates it in Main.
    const entry = ($(raw_string(read(entry, String))), $(here(entry)))
    """)
  print(io, bundle_runner)
  println(io, "\nend")
  String(take!(io))
end

const bundle_runner = raw"""

# Runs after every bundled module's own __init__
__init__() = Kip.restart_lazy()

"Run the entry script in `m`, as if Julia was started with `julia <entry script>`"
function run(m::Module=Main)
  isdefined(m, :Kip) || Core.eval(m, :(const Kip = $Kip))
  Core.eval(m, :(const var"@use" = $(getfield(Kip, Symbol("@use")))))
  Core.eval(m, :(const var"@dirname" = $(getfield(Kip, Symbol("@dirname")))))
  # So `abspath(PROGRAM_FILE) == @__FILE__` still finds the script's main block.
  # Not while JuliaC builds an app: that would run the main block during the build.
  m === Main && !Kip.building_image() && setglobal!(Base, :PROGRAM_FILE, entry[2])
  Kip.load(m, entry[1], entry[2])
end

"Run the entry script in Main as `julia <entry script>` would, including its `@main` function. Returns the exit code."
function script()
  run(Main)
  # `main` was defined after this function started, so look for it in the latest world
  Base.invokelatest() do
    isdefined(Base, :should_use_main_entrypoint) && Base.should_use_main_entrypoint() || return 0
    ret = Main.main(ARGS)
    ret === nothing ? 0 : Cint(ret)
  end
end"""

"""
Write `dir/Project.toml`, which makes the bundle a package named `name`, and
`dir/Manifest.toml`, which pins its packages to the versions `project` uses.
"""
function write_project(dir, name, entry, pkgs, project)
  toml = Dict{String,Any}("deps" => pkgs)
  file = joinpath(project, "Project.toml")
  # A package installed from a URL or a path needs its [sources] entry too
  sources = isfile(file) ? get(TOML.parsefile(file), "sources", empty_deps) : empty_deps
  sources = filter(s -> haskey(pkgs, first(s)), sources)
  isempty(sources) || (toml["sources"] = sources)
  open(joinpath(dir, "Project.toml"), "w") do io
    println(io, "name = ", repr(name))
    println(io, "uuid = ", repr(string(bundle_uuid(entry))))
    println(io, "entryfile = \"bundle.jl\"\n")
    TOML.print(io, toml; sorted=true)
  end
  manifest = joinpath(project, "Manifest.toml")
  isfile(manifest) && cp(manifest, joinpath(dir, "Manifest.toml"), force=true)
  # Pkg keeps the versions the project uses, adds the standard libraries and
  # drops the packages the bundle doesn't need. It runs in its own process so
  # this one doesn't have to load Pkg.
  script = "using Pkg; Pkg.offline(true); Pkg.resolve(io=devnull)"
  try
    Base.run(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$dir -e $script`, stdout=devnull))
  catch
    error("Kip.bundle: Pkg couldn't resolve the packages in $(joinpath(dir, "Project.toml")). Its error is above.")
  end
end
