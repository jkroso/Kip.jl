PREFIX:=/usr/local/bin

dependencies: dependencies.json
	@packin install --folder $@ --meta $<
	@ln -snf .. $@/kip

test: dependencies
	@$</jest/bin/jest.jl index.jl

install: dependencies
	ln -snf $(PWD)/bin/kip.jl $(PREFIX)/kip

.PHONY: test install
