module Kip
# A stand-in for Kip that `Kip.bundle` copies into each bundle. Every `@use`
# was resolved when the bundle was built, so this only looks modules up. It has
# no dependencies, and it never fetches or installs anything.
#
# This file is never loaded by Kip itself. Its `@use` must expand the same way
# as Kip's own `@use` macro.
export @use, @dirname

# sources[i]: the i-th bundled file, in load order: its module's name, its
# path, its source, and whether it's lazy (see `is_lazy`)
const sources = Tuple{Symbol,String,String,Bool}[]
# loaded[i]: the module of sources[i], once `define` has made it
const loaded = Union{Module,Nothing}[]
# The module the bundled modules are defined in: the bundle
const bundle = Ref{Module}()
# (file the @use is in, path written in the @use) => index into `sources`, or
# the PkgId of a GitHub repo that is a normal Julia package
const table = Dict{Tuple{String,String},Union{Int,Base.PkgId}}()
# The same, by path alone, for the paths that mean the same in any file: GitHub
# repos and absolute paths. Code evaluated at a REPL has no file of its own.
const anywhere = Dict{String,Union{Int,Base.PkgId}}()

"Record that `@use \"path\"` in `file` loads `v`"
function resolved!(file::String, path::String, v)
  table[(file, path)] = v
  occursin(r"^\.{1,2}", path) || (anywhere[path] = v)
  v
end

# The same names as Kip's, for code written against Kip. `modules` maps each
# bundled file to its module. `fallback_paths` is empty: Kip uses it to find
# the files it included, whose __init__ nobody else would run, but Julia runs
# the __init__ of every bundled file itself.
const modules = Dict{String,Module}()
const fallback_paths = Set{String}()
__init__() = nothing

# Each bundled file's path => its index in `sources`
const by_path = Dict{String,Int}()

"Add a bundled file. `define` makes its module."
add_source!(name::Symbol, path::String, src::String, lazy::Bool) =
  (push!(sources, (name, path, src, lazy)); push!(loaded, nothing); by_path[path] = length(sources))

"""
The bundled file that `@use "path"` in `file` names, found the way Kip finds it:
`path` itself, with `.jl`, or as a folder's `main.jl`. For a file the bundle
has no record of, such as a plugin the program includes itself.
"""
function find_bundled(file::String, path::String)
  startswith(path, "~/") && (path = homedir() * path[2:end])
  occursin(r"^\.{1,2}", path) && (path = normpath(dirname(file), path))
  isabspath(path) || return nothing
  for p in (path, path * ".jl", joinpath(path, "main.jl"))
    i = get(by_path, ispath(p) ? realpath(p) : p, nothing)
    i === nothing || return i
  end
  nothing
end

# The modules `define` is making
const defining = Set{Int}()

"""
The module of sources[i]. The bundle defines each in load order as it loads,
but a @use of one that comes later defines that one first, as Kip would load
it then.
"""
function define(i::Int)
  m = loaded[i]
  m === nothing || return m
  name, path, src, lazy = sources[i]
  i in defining && error("$path @uses itself as it loads")
  push!(defining, i)
  try
    Core.eval(bundle[], Expr(:module, true, name, Expr(:block,
      :(import ..Kip),
      :(using ..Kip: @use, @dirname),
      :(Kip.load(@__MODULE__, $src, $path; lazy=$lazy)),
      :(Kip.loaded[$i] = @__MODULE__))))
  finally
    delete!(defining, i)
  end
  # The module holds what it needs now, so the bundle needn't keep the source too
  sources[i] = (name, path, "", lazy)
  modules[path] = loaded[i]
end

# is_lazy(i): only files the program includes itself use sources[i], so its
# __init__ waits for the first @use of it, as it would under Kip. Julia doesn't
# know it has one: `load` renames it.
is_lazy(i::Int) = sources[i][4]
# The lazy modules the program has asked for, in load order. A precompiled
# bundle or an app image keeps this, so each process starts them again.
const lazy_asked = Int[]
# The lazy modules whose __init__ has run in the process `started_in`
const lazy_started = Int[]
const started_in = Ref(0)
# True while a lazy module's own source runs. Its @uses don't ask for anything:
# only the program asks for a lazy module.
const defining_lazy = Ref(false)

"True while JuliaC builds an app, when Julia postpones each __init__ to when the app starts"
building_image() = ccall(:jl_generating_output, Cint, ()) == 1 && Base.JLOptions().incremental == 0

"True while Julia precompiles the bundle"
precompiling() = ccall(:jl_generating_output, Cint, ()) == 1 && Base.JLOptions().incremental == 1

# The modules whose postponed __init__ has run while an app is built
const image_started = Set{Int}()

"""
While JuliaC builds an app, run the postponed __init__ of sources[i] and of
each module it needs. Kip runs each file's __init__ as it loads it, and code
that `@use`s a module expects that. Julia runs them all again when the app starts.
"""
function start_needed(i::Int)
  for j in sort!(collect(needs(i)))
    (is_lazy(j) || j in image_started) && continue
    push!(image_started, j)
    m = loaded[j]
    isdefined(m, :__init__) && Base.invokelatest(getfield(m, :__init__))
  end
end

function lookup(file::String, path::String)
  v = get(table, (file, path), nothing)
  # The bundle knows each file by its real path, but a program can include a file through a link
  v === nothing && isfile(file) && (v = get(table, (realpath(file), path), nothing))
  v === nothing && (v = get(anywhere, path, nothing))
  v === nothing && (v = find_bundled(file, path))
  if v === nothing
    isfile(file) || error("This bundle has no module for `@use \"$path\"`. It only has the files it was built with.")
    error("""This bundle has no module for `@use "$path"` in $file. \
             If the program includes $file itself, name it in `includes` when you bundle it.""")
  end
  v isa Base.PkgId && return Base.require(v)
  m = define(v)
  building_image() && start_needed(v)
  is_lazy(v) && v ∉ lazy_asked && ask_lazy(v)
  m
end

"sources[i] and every bundled file it @uses, directly or not"
function needs(i::Int, out::Set{Int}=Set{Int}())
  i in out && return out
  push!(out, i)
  for ((file, _), v) in table
    file == sources[i][2] && v isa Int && needs(v, out)
  end
  out
end

"The program asked for the lazy module of sources[i]: start it, and the lazy modules it needs"
function ask_lazy(i::Int)
  defining_lazy[] && return
  for j in sort!(collect(needs(i)))
    is_lazy(j) && j ∉ lazy_asked && push!(lazy_asked, j)
  end
  # Julia never runs an __init__ while it precompiles. The bundle's own
  # __init__ starts these when it loads.
  precompiling() || start_asked()
end

"Run the deferred __init__ of each lazy module asked for that hasn't run it in this process"
function start_asked()
  started_in[] == getpid() || (empty!(lazy_started); started_in[] = getpid())
  for j in lazy_asked
    j in lazy_started && continue
    push!(lazy_started, j)
    m = define(j)
    isdefined(m, deferred_init) && Base.invokelatest(getfield(m, deferred_init))
  end
end

"""
Start the lazy modules asked for before this process loaded the bundle: while
it was precompiled, or while JuliaC built the app. Julia does the same for
every other module. The bundle's own __init__ calls this, after every module's.
"""
restart_lazy() = start_asked()

"""
Evaluate `src` in `mod` as if it was the file at `path`. Errors and `@__DIR__`
name that file, and an `include` in it finds files next to it.
"""
function load(mod::Module, src::String, path::String; lazy::Bool=false)
  was = defining_lazy[]
  defining_lazy[] = lazy
  try
    task_local_storage(:SOURCE_PATH, path) do
      Base.include_string(lazy ? defer_init ∘ drop_kip_imports : drop_kip_imports, mod, src, path)
    end
  finally
    defining_lazy[] = was
  end
end

# What a lazy module's __init__ is renamed to, so Julia doesn't run it on load
const deferred_init = Symbol("#__init__")

"`__init__() = …` or `function __init__() … end`, renamed to `deferred_init`"
defer_init(ex) =
  Meta.isexpr(ex, (:function, :(=)), 2) && ex.args[1] == :(__init__()) ?
    Expr(ex.head, Expr(:call, deferred_init), ex.args[2]) : ex

"`using Kip`, `import Kip` or `using Kip: …`. The stand-in is already bound in every bundled module."
is_kip_import(ex) =
  Meta.isexpr(ex, (:using, :import), 1) &&
  (ex.args[1] == Expr(:., :Kip) || (Meta.isexpr(ex.args[1], :(:)) && ex.args[1].args[1] == Expr(:., :Kip)))
drop_kip_imports(ex) = is_kip_import(ex) ? nothing : ex

inbrackets(expr) = Meta.isexpr(expr, :vcat) || Meta.isexpr(expr, :hcat) || Meta.isexpr(expr, :vect)
tovcat(n) =
  if Meta.isexpr(n, :hcat) || Meta.isexpr(n, :vect)
    Expr(:vcat, Expr(:row, n.args...))
  else
    Expr(:vcat, map(torow, n.args)...)
  end
torow(n) = Meta.isexpr(n, :row) ? n : Expr(:row, n)
ispair(ex) = Meta.isexpr(ex, :call, 3) && ex.args[1] === :(=>)

"(path, alias, splatall) for a path form of @use, or nothing for a package form"
function pathform(first)
  first isa String && return (first, nothing, false)
  ispair(first) && first.args[2] isa String && return (first.args[2], first.args[3], false)
  Meta.isexpr(first, :..., 1) && first.args[1] isa String && return (first.args[1], nothing, true)
  nothing
end

"Get the directory the current file was in when the bundle was built"
macro dirname() dirname(String(__source__.file)) end

"Import a bundled file, or a registered package, the way Kip's `@use` does"
macro use(first, rest...)
  pf = pathform(first)
  if pf === nothing
    # A registered package: the same rewrite as Kip's, but it never installs anything
    str = replace(repr(first), r"#= [^=]* =#" => "", "()" => "")
    str = replace(str, r"^:\({0,2}([^\)]+)\){0,2}$" => s"import \1")
    str = replace(str, r"^import (.*)\.{3}$" => s"using \1")
    if length(rest) >= 2 && rest[1] === :as && rest[2] isa Symbol
      str *= " as $(rest[2])"
    end
    return quote $(Meta.parse(str)) end
  end
  path, alias, splatall = pf
  file = String(__source__.file)
  # Looked up only when needed: a @use of nothing but [bracketed] files never loads `path` itself
  found = Ref{Module}()
  m() = isassigned(found) ? found[] : (found[] = lookup(file, path))
  if alias !== nothing
    name = esc(alias)
  else
    isempty(rest) && !splatall && return m()
    name = Symbol(path)
  end
  names = collect(Any, rest)
  if splatall
    mn = nameof(m())
    append!(names, filter(Base.names(m())) do name
      name == mn && return false
      !occursin(r"^(?:[#⭒]|eval|include$)|/", String(name))
    end)
  end
  exprs = []
  i = 0
  while i < length(names)
    n = names[i += 1]
    if Meta.isexpr(n, :macrocall)
      append!(names, n.args)
    elseif Meta.isexpr(n, :..., 1)
      splat = n.args[1]
      if splat == :exports
        mn = nameof(m())
        append!(names, filter(n -> n != mn, Base.names(m())))
      else
        for n in Base.names(getfield(m(), splat), all=true)
          n == splat || occursin(r"^(?:[#⭒]|eval$)|/", String(n)) && continue
          push!(exprs, :(const $(esc(n)) = getfield(getfield($(m()), $(QuoteNode(splat))), $(QuoteNode(n)))))
        end
      end
    elseif ispair(n)
      from, to = n.args[2], n.args[3]
      push!(exprs, :(const $(esc(to)) = $(m()).$from))
    elseif inbrackets(n)
      for row in tovcat(n).args
        relpath, rest = (row.args[1], row.args[2:end])
        firstarg = ispair(relpath) ? :($(normpath(path, relpath.args[2])) => $(relpath.args[3])) : normpath(path, relpath)
        push!(exprs, esc(macroexpand(__module__, Expr(:macrocall, getfield(Kip, Symbol("@use")), __source__, firstarg, rest...))))
      end
    elseif n isa LineNumberNode
    else
      @assert n isa Symbol "Expected a Symbol, got $(repr(n))"
      push!(exprs, :(const $(esc(n)) = $(m()).$n))
    end
  end
  if isempty(exprs)
    Meta.isexpr(name, :escape) ? :(const $name = $(m())) : m()
  elseif all(inbrackets, names)
    quote $(exprs...) end
  else
    quote
      const $name = $(m())
      $(exprs...)
      $name
    end
  end
end

end
