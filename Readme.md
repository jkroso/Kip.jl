# Kip

Kip is an alternative module system for Julia with the goal of being more robust and easier to use. With Kip __packages don't have names__. So you can have several versions of the same package without them overwriting each other. Also it favours putting __dependency info inline__ rather than in a REQUIRE file. This reduces indirection and works well in the REPL.

```julia
julia> @require "github.com/jkroso/emitter.jl/index.jl" emit
```

The final key differences is that it __installs dependencies at runtime__. So users never think about installing or updating their packages. It would also make hot module reloading a lot easier if I ever decide to attempt that feature.

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
