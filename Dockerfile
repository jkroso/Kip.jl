FROM debian:jessie

ARG JULIA_VERSION=1.7.1
ENV JULIA_PATH=/usr/local/julia

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && apt-get install -y curl \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir $JULIA_PATH \
  && curl -sSL "https://julialang-s3.julialang.org/bin/linux/x64/${JULIA_VERSION%[.]*}/julia-${JULIA_VERSION}-linux-x86_64.tar.gz" -o julia.tar.gz \
  && tar -xzf julia.tar.gz -C $JULIA_PATH --strip-components 1 \
  && rm julia.tar.gz

ENV PATH=$JULIA_PATH/bin:$PATH

RUN ["julia", "-e", "import Pkg;Pkg.add(url=\"https://github.com/jkroso/Kip.jl.git\")"]
RUN mkdir -p /root/.julia/config
COPY startup.jl /root/.julia/config/startup.jl

ENTRYPOINT julia
