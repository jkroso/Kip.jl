import Pkg
if any(x->x.name == "Kip", values(Pkg.dependencies()))
  eval(:(using Kip))
end
