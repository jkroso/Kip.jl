FROM julia

RUN apt-get update && apt-get install -y \
	cmake \
	make \
	curl

RUN ["julia", "-e", "Pkg.clone(\"https://github.com/jkroso/Kip.jl.git\")"]
COPY .juliarc.jl /root

# command to run after the container boots
ENTRYPOINT julia
