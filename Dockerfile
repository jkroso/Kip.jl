FROM debian:jessie

ARG JULIA_VERSION=0.6.0-rc3
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

RUN ["julia", "-e", "Pkg.clone(\"https://github.com/jkroso/Kip.jl.git\")"]
COPY .juliarc.jl /root

ENTRYPOINT julia