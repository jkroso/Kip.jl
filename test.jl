import Kip

path = Kip.download("http://github.com/jkroso/Jest.jl/tarball/df8f756")
@assert ispath(joinpath(path, "index.jl"))

@assert Kip.resolve_gh("github.com/jkroso/Jest.jl") == ("http://github.com/jkroso/Jest.jl/tarball/d3fb269","")
@assert Kip.latest_gh_commit("jkroso", "Jest.jl")[1:7] == "d3fb269"
@assert Kip.resolve_gh_tag("jkroso", "Jest.jl", "0") == v"0.0.3"
