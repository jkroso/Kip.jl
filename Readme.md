# Kip

Kip wraps the built in package manager to fix the aesthetic nightmare that is module declarations and Project.toml files

## Installation

```julia
Pkg.clone("https://github.com/jkroso/Kip.jl.git")
```

Then add this code to your ~/.julia/config/startup.jl

```julia
using Kip
```

Now it's like Kip was built into Julia. It will be available at the REPL and in any files you run

## API

```julia
@use SQLite... # becomes using SQLite
@use SQLite: DB # becomes import SQLite: DB
@use "github.com/jkroso/SQL.jl" DB # downloads the package from github and imports the variable DB from $pkg/main.jl
@use "github.com/jkroso/SQL.jl" => SQL # gives the imported module a name
@use "." # imports pwd()*"/main.jl"
@use "./test" test @testset # imports pwd()*"/test.jl" and imports 2 variables from it one of which is a macro
@use "github.com/jkroso/SQL.jl/query" # imports $pkg/query.jl
@use "github.com/jkroso/SQL.jl" db ["query" q] # imports $pkg/main.jl amd $pkg/query.jl
@use "github.com/jkroso/SQL.jl@v3" # downlaods the v3 branch of the package instead of the default branch
```

Besides that just forget everything else you know about packages in Julia

## Bundles

`Kip.bundle` writes a script and every file it `@use`s into one file. The bundle runs without Kip, Git or LibGit2. Each `@use` is resolved when you make the bundle, not when it runs.

```julia
using Kip
Kip.bundle("app.jl", "build/app")
```

This writes four files to `build/app`:

- `bundle.jl` holds the source of each file, in its own module.
- `Project.toml` and `Manifest.toml` list the registered packages that the files use, at the versions in your project.
- `juliac.jl` is the file to give JuliaC when you build an app from the bundle.

Run the bundle as you would run the script:

```sh
julia build/app/bundle.jl [arguments]
```

The bundle is also a package. Julia compiles it the first time it runs, and loads it from that cache after that. Pass `precompile=false` if your files must run their top-level code each time the bundle starts.

Some things to know:

- The bundle is a snapshot. If you change a file, make the bundle again.
- `@__DIR__` and `@dirname` still give the folders the files came from. A bundle that reads data files next to its source needs those files on the machine that runs it.
- A file that another file loads with `include` isn't in the bundle. The bundle reads it from where it was. When the path is in the source, such as `include("x.jl")` or `include(joinpath(@__DIR__, "x.jl"))`, the bundle also holds every file that file `@use`s.
- If your program finds the files it includes while it runs, such as plugins in a folder, name them with `includes`. The plugins stay where they are, but the bundle holds every file they `@use`:

  ```julia
  Kip.bundle("cli.jl", "build/cli"; includes=["tools", "commands"])
  ```

  A plugin needs no `includes` if the bundle already holds every file it `@use`s.
- A module that only included files use starts (runs its `__init__`) when one of them first `@use`s it, as it would under Kip. This happens when an `includes` file uses it, or a file that a function includes. Other modules start when the bundle loads.
- Code evaluated while the bundle runs, such as code typed at a REPL, can `@use` a GitHub repo or an absolute path only if the bundle holds that file.
- In a bundle, `Kip` is a small stand-in. It has `@use`, `@dirname`, `Kip.modules` and `Kip.fallback_paths`, but not Kip's other functions, such as `Kip.require`.
