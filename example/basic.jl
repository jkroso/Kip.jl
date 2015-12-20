@require "github.com/jkroso/emitter.jl/index.jl" emit Events

emit(Events("a" => () -> println("a fired")), "a")
