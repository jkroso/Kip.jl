install:
	ln -fs $$PWD `julia -e 'print(Pkg.dir("Kip"))'`

test:
	julia test.jl

.PHONY: install test
