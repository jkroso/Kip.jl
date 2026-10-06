using Test
pushfirst!(LOAD_PATH, joinpath(@__DIR__, ".."))
using Kip

const kip_root = dirname(@__DIR__)
const julia = joinpath(Sys.BINDIR, Base.julia_exename())
const app = joinpath(@__DIR__, "fixtures", "bundle", "app")
# Compile caches for the bundles go here, not in ~/.julia. The user's depot
# stays next, where the registered packages are, then Julia's own depots (the
# trailing separator).
const depot = mktempdir()
const sep = Sys.iswindows() ? ";" : ":"
const depot_path = depot * sep * first(DEPOT_PATH) * sep

"Run `cmd` and return (stdout, stderr, exit code)"
function run_julia(cmd; env=())
  out, err = IOBuffer(), IOBuffer()
  p = run(pipeline(ignorestatus(addenv(cmd, env...)), stdout=out, stderr=err))
  String(take!(out)), String(take!(err)), p.exitcode
end
"(module name, path, lazy) for each file in the bundle `file`"
function bundled(file)
  pkg = only(ex for ex in Meta.parseall(read(file, String)).args if Meta.isexpr(ex, :module))
  [(String(eval(ex.args[2])), ex.args[3], ex.args[5]) for ex in pkg.args[3].args
   if Meta.isexpr(ex, :call) && ex.args[1] == :(Kip.add_source!)]
end
run_bundle(file, args...) =
  run_julia(`$julia --startup-file=no $file $args`; env=("JULIA_DEPOT_PATH" => depot_path,))

@testset "Kip.bundle" begin
  @testset "parsing @use calls" begin
    ex = Meta.parseall("""
      @use "./a" x y => z
      @use "./b" => B
      @use "./c"... d
      @use "../lib" ["utils" u] ["sub/utils" v]
      @use "github.com/jkroso/Prospects.jl" @def ["Enum.jl" @Enum]
      @use Dates: Date
      """)
    paths = Kip.use_paths!(String[], ex)
    @test paths == ["./a", "./b", "./c", "../lib/utils", "../lib/sub/utils",
                    "github.com/jkroso/Prospects.jl", "github.com/jkroso/Prospects.jl/Enum.jl"]
    # A @use of only [bracketed] files never loads its base path
    @test "../lib" ∉ paths
  end

  @testset "finding the packages files load" begin
    ex = Meta.parseall("""
      @use Reseau: TLS, TCP
      @use Base64...
      @use SQLite: DB
      @use JSON3 as J
      using Dates, .Local
      import Foo: bar
      using Base.Iterators
      f() = quote using NotLoaded end
      """)
    names = Kip.package_names!(Set{String}(), ex)
    @test names == Set(["Reseau", "Base64", "SQLite", "JSON3", "Dates", "Foo", "Base"])
  end

  @testset "package names" begin
    @test Kip.bundle_name("app.jl") == "AppBundle"
    @test Kip.bundle_name("examples/26_finder.jl") == "Bundle26Finder"
    @test Kip.bundle_name("/x/LLM.jl/main.jl") == "LLMBundle"
    @test cd(() -> Kip.bundle_name("main.jl"), app) == "AppBundle"
  end

  @testset "module names are unique" begin
    names = Kip.module_names(["/x/lib/utils.jl", "/x/lib/sub/utils.jl", "/x/lib/main.jl"], "app")
    @test names == [Symbol("a/utils"), Symbol("a/utils~2"), :⭒lib]
  end

  dir = mktempdir()
  project = mktempdir() # no packages of its own: the app only uses Dates
  file = Kip.bundle(joinpath(app, "main.jl"), dir; project)

  @testset "writes a package" begin
    @test file == joinpath(dir, "bundle.jl")
    @test isfile(joinpath(dir, "juliac.jl"))
    @test isfile(joinpath(dir, "Manifest.toml"))
    toml = Kip.TOML.parsefile(joinpath(dir, "Project.toml"))
    @test toml["name"] == "AppBundle"
    @test toml["entryfile"] == "bundle.jl"
    @test toml["deps"] == Dict("Dates" => Kip.stdlib_uuids["Dates"])
    mods = first.(bundled(file))
    @test allunique(mods)
    @test count(m -> endswith(m, "utils") || endswith(m, "utils~2"), mods) == 2
  end

  @testset "runs like the script runs under Kip" begin
    kip_out, _, kip_code = run_julia(`$julia --startup-file=no --project=$kip_root $(joinpath(app, "main.jl")) a b`)
    for run in 1:2 # run 1 compiles the bundle, run 2 loads it from that cache
      out, err, code = run_bundle(file, "a", "b")
      @test out == kip_out
      @test code == kip_code == 3
      @test occursin("LibGit2 loaded: false", err)
    end
  end

  @testset "precompile=false" begin
    dir = Kip.bundle(joinpath(app, "main.jl"), mktempdir(); project, precompile=false) |> dirname
    @test occursin("__precompile__(false)", read(joinpath(dir, "bundle.jl"), String))
    out, _, code = run_bundle(joinpath(dir, "bundle.jl"), "a", "b")
    @test startswith(out, "hello bundle\n")
    @test code == 3
  end

  @testset "a script's main block runs" begin
    file = Kip.bundle(joinpath(app, "script.jl"), mktempdir(); project)
    out, _, code = run_bundle(file)
    @test out == "main block ran: c\n"
    @test code == 0
  end

  @testset "files the program includes itself" begin
    host = joinpath(app, "host.jl")
    plugins = joinpath(app, "plugins")
    file = Kip.bundle(host, mktempdir(); project, includes=[plugins])
    out, err, code = run_bundle(file)
    @test out == "plugin uses c\n"
    @test code == 0
    # Without `includes` the bundle can't know what the plugin @uses, and says how to fix that
    file = Kip.bundle(host, mktempdir(); project)
    out, err, code = run_bundle(file)
    @test code == 1
    @test occursin("name it in `includes`", err)
  end

  @testset "a plugin needs no `includes` when the bundle has what it @uses" begin
    file = Kip.bundle(joinpath(app, "sharedhost.jl"), mktempdir(); project)
    out, _, code = run_bundle(file)
    @test out == "plugin uses c\n"
    @test code == 0
  end

  @testset "a file included by a path written in the source" begin
    file = Kip.bundle(joinpath(app, "withinc.jl"), mktempdir(); project)
    out, _, code = run_bundle(file)
    @test out == "part uses c\n"
    @test code == 0
  end

  @testset "a module only an included file needs starts when first used, as under Kip" begin
    host = joinpath(app, "lazyhost.jl")
    file = Kip.bundle(host, mktempdir(); project)
    @test [basename(p) for (_, p, lazy) in bundled(file) if lazy] == ["noisy.jl"]
    for args in ([], ["--plugin"])
      kip_out, _, kip_code = run_julia(`$julia --startup-file=no --project=$kip_root $host $args`)
      out, _, code = run_bundle(file, args...)
      @test out == kip_out
      @test code == kip_code == 0
    end
  end

  @testset "a lazy module asked for as the bundle loads starts then" begin
    entry = joinpath(app, "askearly.jl")
    file = Kip.bundle(entry, mktempdir(); project)
    kip_out, _, _ = run_julia(`$julia --startup-file=no --project=$kip_root $entry`)
    @test kip_out == "noisy started\npart got noisy\n"
    for run in 1:2 # run 1 asks for it while precompiling, run 2 loads that cache
      out, _, code = run_bundle(file)
      @test out == kip_out
      @test code == 0
    end
  end

  @testset "code with no file, like a REPL, can @use a bundled module by an absolute path" begin
    c = realpath(joinpath(app, "..", "lib", "c.jl"))
    entry = joinpath(mktempdir(), "abs.jl")
    write(entry, "@use $(repr(c)) cname\nprintln(cname())\n")
    dir = dirname(Kip.bundle(entry, mktempdir(); project))
    repl = """
      using AbsBundle
      m = Module()
      Core.eval(m, :(const Kip = \$(AbsBundle.Kip)))
      Core.eval(m, :(using .Kip))
      println(Base.include_string(m, $(repr("@use $(repr(c)) cname; cname()"))))
      try
        Base.include_string(m, $(repr("@use \"./elsewhere\" x")))
      catch e
        println(sprint(showerror, e))
      end
      """
    out, _, code = run_julia(`$julia --startup-file=no --project=$dir -e $repl`; env=("JULIA_DEPOT_PATH" => depot_path,))
    @test code == 0
    @test startswith(out, "c\n")
    @test occursin("It only has the files it was built with", out)
  end

  @testset "a package the project doesn't have" begin
    @test_throws ErrorException Kip.bundle(joinpath(app, "missing_pkg.jl"), mktempdir(); project)
  end
end
