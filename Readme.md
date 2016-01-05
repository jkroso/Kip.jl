# Kip

Kip is an alternative module system for Julia with the goal of being more robust and easier to use. With Kip __packages don't have names__. Instead modules are identified by the file they are in. So you can have several versions of the same package without them overwriting each other. Also it favors putting __dependency info inline__ rather than in a REQUIRE file. This reduces indirection and works well at the REPL. The final key difference is that it __installs dependencies at runtime__. So users never think about installing or updating their packages.

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

`@require` takes a path to a package and a list of symbols to import from that package. If you want to use a different name locally for any of these symbols your can pass a `Pair` of symbols like `@require "./thing" a => b`. This will import `a` from the local package `"./thing"` and make it available as `b`.

Now I just need to explain the syntax of the path parameter. In this example I'm using a relative path which is resolved relative to the REPL's `pwd()`. Or if I was editing a file it would be the `dirname()` of that file. This should be familiar for people who use unix machines. Now, assuming we are at the REPL, what `@require` does under the hood is check for a file called `joinpath(pwd(), "./thing")`. If it exists it will load it. Otherwise it tries a few other paths `joinpath(pwd(), "./thing.jl")`, `joinpath(pwd(), "./thing/main.jl")`, and `joinpath(pwd(), "./thing/src/thing.jl")`. This just enables you to save a bit of typing if you feel like it.

There are a couple other types of paths you can pass to `@require`:

- Absolute: `@require "/Users/jkroso/thing"`
- Github: `@require "github.com/jkroso/thing"`

  This syntax is actually pretty complex since it also needs to enable you to specify which ref (tag/commit/branch) you want to use. Here I haven't specified a ref so it uses the latest commit. If I want to specify one I put it after the reponame prefixed with an "@". e.g: `@require "github.com/jkroso/thing@1"` This looks like a semver query so it will be run over all tags in the repo and the latest tag that matches the query is the one that gets used. Finally, if the module we want from the repository isn't called "main.jl", or "src/$(reponame).jl" then we will need to specify its path. e.g: `@require "github.com/jkroso/thing@1/thing"`. And path completion will also be applied just like with relative and absolute paths.

### `@dirname()`

`@dirname` is the other macro in Kip's API. It just returns the `dirname` of the file currently being run. Or if we are at the REPL it returns `pwd()`. You won't use it often but when you do you will be glad its there.

## The Kip workflow

With kip developing Julia is really simple. You just write code then `@require` in the stuff you need at the top of the file (or anywhere you like really). If the file you are working on gets big you might be able to find a separate module within it. To separate this module out just cut and paste it into a separate file then `@require` the bits you need back in to the original file. This is way better than using `include` since it's clear to the reader which symbols the other module provides. To run your code you just run it. e.g: `julia mycode.jl`. All dependencies will be loaded/updated as required.

## Prospective features

### Automatic reloading of modules

While at the REPL it could listen to changes on the modules you require and automatically reload them into the workspace.

### Dependency tree linting

Kips ability to load multiple versions of a module at the same time is a double edged sword. The upside is package developers can make breaking changes to their API's without instantly breaking all their dependent projects. The downside is that if you and your dependencies have dependencies in common and they load different versions of these modules to you then you might run into issues if you passing Type instances back and fourth between your direct dependencies. This is a subtle problem which can be hard to recognize. Especially if you not aware that it can happen. A good solution to this might be to use a static analysis tool to check your dependency tree for potential instances of this problem. It would make sense to make it part of a [linting tool](//github.com/tonyhffong/Lint.jl).

### Offline mode

Kip currently updates all dependencies everytime a file is run. This slows down startup time significantly. It would be nice to have a local mode which only downloads new dependecies and just assumes old ones are still up to date.