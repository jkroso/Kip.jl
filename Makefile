install:
	@julia --startup-file=no -e 'symlink(pwd(), Pkg.dir("Kip"))'

test:
	julia test.jl

.PHONY: install test
