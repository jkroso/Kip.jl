module Kip
# A stand-in for Kip that `Kip.bundle` copies into each bundle. Every `@use`
# was resolved when the bundle was built, so this only looks modules up. It has
# no dependencies, and it never fetches or installs anything.
#
# This file is never loaded by Kip itself. Its `@use` must expand the same way
# as Kip's own `@use` macro.
export @use, @dirname

# loaded[i] is the module of the i-th bundled file, in load order
const loaded = Module[]
# (file the @use is in, path written in the @use) => index into `loaded`, or the
# PkgId of a GitHub repo that is a normal Julia package
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

register(mod::Module, path::String) = (push!(loaded, mod); modules[path] = mod; mod)

"True while JuliaC builds an app, when Julia postpones each __init__ to when the app starts"
building_image() = ccall(:jl_generating_output, Cint, ()) == 1 && Base.JLOptions().incremental == 0

# How many of `loaded` have run their __init__ while an app is built
const started = Ref(0)

"""
While JuliaC builds an app, run the postponed __init__ of `loaded[1:i]`. Kip
runs each file's __init__ as it loads it, and code that `@use`s a module
expects that. Julia runs them all again when the app starts.
"""
start_through(i::Int) =
  while started[] < i
    m = loaded[started[] += 1]
    isdefined(m, :__init__) && Base.invokelatest(getfield(m, :__init__))
  end

function lookup(file::String, path::String)
  v = get(table, (file, path), nothing)
  # The bundle knows each file by its real path, but a program can include a file through a link
  v === nothing && isfile(file) && (v = get(table, (realpath(file), path), nothing))
  v === nothing && (v = get(anywhere, path, nothing))
  if v === nothing
    isfile(file) || error("This bundle has no module for `@use \"$path\"`. It only has the files it was built with.")
    error("""This bundle has no module for `@use "$path"` in $file. \
             If the program includes $file itself, name it in `includes` when you bundle it.""")
  end
  v isa Base.PkgId && return Base.require(v)
  building_image() && start_through(v)
  loaded[v]
end

"""
Evaluate `src` in `mod` as if it was the file at `path`. Errors and `@__DIR__`
name that file, and an `include` in it finds files next to it.
"""
load(mod::Module, src::String, path::String) =
  task_local_storage(:SOURCE_PATH, path) do
    Base.include_string(drop_kip_imports, mod, src, path)
  end

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
