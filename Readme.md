# Kip

Kip is an alternative module system for Julia with the goal of being more robust and easier to use. With Kip __packages don't have names__. Instead modules are identified by the file they are in. So you can have several versions of the same package without them overwriting each other. Also it favours putting __dependency info inline__ rather than in a REQUIRE file. This reduces indirection and works well at the REPL. The final key difference is that it __installs dependencies at runtime__. So users never think about installing or updating their packages.

## Installation

```sh
git clone https://github.com/jkroso/Kip.jl.git kip
ln -fs `realpath kip` `julia -e 'print(Pkg.dir("Kip"))'`
```

Then add this code to your ~/.juliarc.jl

```julia
using Kip
# If we are running a file and not at the REPL
if !isinteractive() && !isempty(ARGS)
  # set Kip.entry to the dirname of the file being run
  Kip.eval(:(entry=$(dirname(realpath(joinpath(pwd(), ARGS[1]))))))
end
```

Now it's like Kip was built into Julia. It will be available at the REPL and in any files you run

## API

Kip's API consists of just two macros and to get started you only need to know the first one.

### `@require(pkg::String, imports::Symbol...)`

`@require` takes a path to a package and a list of symbols to import from that package. If you want to use a different name locally for any of these symbols your can pass a `Pair` of symbols like `@require "./thing" a => b`. This will import `a` from the local package `"./thing"` and make it available as `b`. Now I just need to explain the syntax of the path parameter. In this example we a using a relative path from the file we are working in. Or if we are at the REPL it would be relative to the `pwd()`. The syntax for relative imports is inspired by unix paths. Now assuming we are at the REPL what `@require` does under the hood is checks for a file called `joinpath(pwd(), "./thing")`. If it exists it will load it. Otherwise it checks a couple other paths `joinpath(pwd(), "./thing.jl")` and `joinpath(pwd(), "./thing/main.jl")`. This just enables you to save a bit of typing if you feel like it. There are a couple other types of paths you can pass to `@require`:

- Absolute: `@require "/Users/jkroso/thing" a`
- Github: `@require "github.com/jkroso/thing" a`

  This syntax is actually pretty complex since it also needs to enable you to specify which ref (tag/commit/branch) you want to use. Here I haven't specified a ref so it uses the latest commit. If I want to specify one I put it after the reponame prefixed with an "@". e.g: `@require "github.com/jkroso/thing@1" a` This looks like a semver query so it will be run over all tags in the repo with the latest matching tag being the one that gets used. Finally if the module we want from the repository isn't called "main.jl" then we will need to specify its path. e.g: `@require "github.com/jkroso/thing@1/thing" a`. Path completion will also be applied just like with relative paths so the module might actually be called "thing.jl" or "thing/main.jl"

### `@dirname()`

`@dirname` is the other macro in Kip's API. It just returns the `dirname` of the file currently being run. Or if we are at the REPL it returns `pwd()`. You won't use it often but when you do you will be glad its there.
