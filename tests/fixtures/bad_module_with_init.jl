initialized = Ref(false)

__init__() = initialized[] = true

# This will fail to precompile because it evals into a closed module
Base.eval(Main, :(injected_var_init = 42))
