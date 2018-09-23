# Kip

Kip is an alternative module system for Julia with the goal of being more robust and easier to use. With Kip __packages don't have names__. Instead modules are identified by the file they are in. So you can have several versions of the same package without them overwriting each other. Also it favors putting __dependency info inline__ rather than in a REQUIRE file. This reduces indirection and works well at the REPL. The final key difference is that it __installs dependencies at runtime__. So you never have to think about if a package is installed or not. Though you should run `Kip.update()` occasionally to update Kip's local cache of packages which are just plain Git repositories.

## Installation

```julia
Pkg.clone("https://github.com/jkroso/Kip.jl.git")
```

Then add this code to your ~/.julia/config/startup.jl

```julia
import Pkg
if haskey(Pkg.installed(), "Kip")
  eval(:(using Kip))
end
```

Now it's like Kip was built into Julia. It will be available at the REPL and in any files you run

## API

Kip's API consists of just one macro to import modules. And one function to update all the 3rd party repositories you use

### `@require(pkg::String, imports::Symbol...)`

`@require` takes a path to a package and a list of symbols to import from that package. If you want to use a different name locally for any of these symbols your can pass a `Pair` of symbols like `@require "./thing" a => b`. This will import `a` from the local package `"./thing"` and make it available as `b`.

Now I just need to explain the syntax of the path parameter. In this example I'm using a relative path which is resolved relative to the REPL's `pwd()`. Or if I was editing a file it would be the `dirname()` of that file. This should be familiar for people who use Unix machines. Now, assuming we are at the REPL, what `@require` does under the hood is check for a file called `joinpath(pwd(), "./thing")`. If it exists it will load it. Otherwise it tries a few other paths `joinpath(pwd(), "./thing.jl")`, `joinpath(pwd(), "./thing/main.jl")`, and `joinpath(pwd(), "./thing/src/thing.jl")`. This just enables you to save a bit of typing if you feel like it.

There are a couple other types of paths you can pass to `@require`:

- Absolute: `@require "/Users/jkroso/thing"`
- Github: `@require "github.com/jkroso/thing"`

  This syntax is actually pretty complex since it also needs to enable you to specify which ref (tag/commit/branch) you want to use. Here I haven't specified a ref so it uses the latest commit. If I want to specify one I put it after the reponame prefixed with an "@". e.g: `@require "github.com/jkroso/thing@1"` This looks like a semver query so it will be run over all tags in the repo and the latest tag that matches the query is the one that gets used. Finally, if the module we want from the repository isn't called "main.jl", or "src/$(reponame).jl" then we will need to specify its path. e.g: `@require "github.com/jkroso/thing@1/thing"`. And path completion will also be applied just like with relative and absolute paths.

### `update()`

Runs `git fetch` on all the repositories you have `@require`'d in the past. So that next time you `@require` them you will get the latest version

### Native Julia module support

If the module you require is registered in `Pkg.dir("METADATA")` then it will be installed and loaded using the built in module system. So  `@require "github.com/johnmyleswhite/Benchmark.jl" compare` is exactly equivalent to `import Benchmark: compare`. This reduces the likelihood of ending up with duplicate modules being loaded within `Kip` and `Pkg`'s respective caches. Especially while Julia doesn't provide any good way to load non-registered modules.

Kip also supports non-registered modules by looking at the contents of the file you are requiring to see if the only thing in it is a `Module`. When that's the case it will unbox it from the wrapper Kip normally uses. If Julia ever provides good support for non-registered modules itself then Kip will `Pkg.clone` the module and `import` it to match its handling of registered modules.

## Running arbitrary code on another machine

Since dependencies are declared in the code you can pipe arbitrary code into a machine running Julia and have the results piped back. Or on the other hand you could `curl $url | julia` to run remote code on your local machine. Here is an example of running some code through a docker instance (BTW so long as you have docker installed you can run this)

```bash
$ echo '@require "github.com/coiljl/URI" encode; encode("1 <= 2")' | docker run -i jkroso/kip.jl
"1%20%3C=%202"
```

## Example projects

##### [Jest](//github.com/jkroso/Jest.jl)

This demonstrates mixed use of native modules and Kip modules. It also shows how nice Kip is for writing CLI programs. Since its dependencies will be installed at runtime Jest's CLI script only needs to be downloaded and put in the user's $PATH.

##### [URI parser benchmark](//github.com/coiljl/URI/blob/master/Readme.ipynb)

Here Kip enabled me to put my benchmark code directly in this projects Readme.ipynb file since I didn't need to worry about installing the dependencies.

##### [packin](//github.com/jkroso/packin/blob/d2103c4937f3303fd2f94e7f8bda4cd176020f23/packin#L2)

Here I'm using a fork of a registered module (AnsiColor) while I wait for the projects owner to review the pull request.

## Prospective features

##### Automatic reloading of modules

While at the REPL it could listen to changes on the modules you require and automatically reload them into the workspace.

##### Dependency tree linting

Kips ability to load multiple versions of a module at the same time is a double edged sword. The upside is package developers can make breaking changes to their API's without instantly breaking all their dependent projects. The downside is that if you and your dependencies have dependencies in common and they load different versions of these modules to you then you might run into issues if you passing Type instances back and fourth between your direct dependencies. This is a subtle problem which can be hard to recognize. Especially if you not aware that it can happen. A good solution to this might be to use a static analysis tool to check your dependency tree for potential instances of this problem. It would make sense to make it part of a [linting tool](//github.com/tonyhffong/Lint.jl).
