using Kip

# If we are running a file and not at the REPL
if !isinteractive() && !isempty(ARGS)
  # set Kip.entry to the dirname of the file being run
  Kip.eval(:(entry=$(dirname(realpath(joinpath(pwd(), ARGS[1]))))))
end

# a lot of my packages depend on this being loaded
@require "github.com/jkroso/Jest.jl@8cfc487"
