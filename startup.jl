import Pkg
if haskey(Pkg.installed(), "Kip")
  eval(:(using Kip))
end