import Kip

path = Kip.resolve_github("github.com/jkroso/Jest.jl@0.0.1")
@assert path[end-39:end] == "2e6ab717b4dde474ea55d988588ba3b72a42b933"
