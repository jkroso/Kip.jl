PREFIX:=/usr/local/bin

install:
	ln -fs $$PWD `julia -e 'print(Pkg.dir("Kip"))'`
	ln -snf $(PWD)/bin/kip.jl $(PREFIX)/kip

test:
	julia test.jl

.PHONY: install test
