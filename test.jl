import Kip

path = Kip.download("http://github.com/jkroso/Jest.jl/tarball/f015257")
@assert ispath(joinpath(path, "main.jl"))

@assert Kip.resolve_gh("github.com/jkroso/Jest.jl@0") == ("http://github.com/jkroso/Jest.jl/tarball/0.0.3","")
@assert Kip.latest_gh_commit("jkroso", "Kip.jl")[1:7] == readall(`git log -n 1 --oneline`)[1:7]
@assert Kip.resolve_gh_tag("jkroso", "Jest.jl", "0") == v"0.0.3"
