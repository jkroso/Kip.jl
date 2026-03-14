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
