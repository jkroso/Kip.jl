
dependencies: dependencies.json
	@packin install --folder $@ --meta $<
	@ln -snf .. $@/kip

test: dependencies
	@$</jest/bin/jest index.jl

.PHONY: test
