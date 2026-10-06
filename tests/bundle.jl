using Test
pushfirst!(LOAD_PATH, joinpath(@__DIR__, ".."))
using Kip

const kip_root = dirname(@__DIR__)
const julia = joinpath(Sys.BINDIR, Base.julia_exename())
const app = joinpath(@__DIR__, "fixtures", "bundle", "app")
# Compile caches for the bundles go here, not in ~/.julia. The trailing
# separator keeps the default depots, where the registered packages are.
const depot = mktempdir()
const sep = Sys.iswindows() ? ";" : ":"

"Run `cmd` and return (stdout, stderr, exit code)"
function run_julia(cmd; env=())
  out, err = IOBuffer(), IOBuffer()
  p = run(pipeline(ignorestatus(addenv(cmd, env...)), stdout=out, stderr=err))
  String(take!(out)), String(take!(err)), p.exitcode
end
run_bundle(file, args...) =
  run_julia(`$julia --startup-file=no $file $args`; env=("JULIA_DEPOT_PATH" => depot * sep,))

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
    src = read(file, String)
    mods = [m[1] for m in eachmatch(r"^module var\"([^\"]+)\"$"m, src)]
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

  @testset "a package the project doesn't have" begin
    @test_throws ErrorException Kip.bundle(joinpath(app, "missing_pkg.jl"), mktempdir(); project)
  end
end
