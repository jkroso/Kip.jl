# This will fail to precompile because it evals into a closed module
Base.eval(Main, :(injected_var = 42))
