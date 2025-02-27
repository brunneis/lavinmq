# Base layer
FROM 84codes/crystal:1.8.0-ubuntu-22.04 AS base
WORKDIR /tmp
COPY shard.yml shard.lock .
RUN shards install --production
COPY ./static ./static
COPY ./views ./views
COPY ./src ./src

# Run specs on build platform
FROM base AS spec
COPY ./spec ./spec
ARG spec_args="--order random"
RUN crystal spec ${spec_args}

# Lint in another layer
FROM base AS lint
RUN shards install # install ameba only in this layer
COPY .ameba.yml .
RUN bin/ameba
RUN crystal tool format --check

# Build docs in npm container
FROM node:lts AS docbuilder
WORKDIR /tmp
RUN npm install redoc-cli @stoplight/spectral-cli
COPY Makefile shard.yml .
COPY openapi openapi
RUN make docs

# Build
FROM base AS builder
COPY Makefile .
RUN make js lib
COPY --from=docbuilder /tmp/openapi/openapi.yaml /tmp/openapi/.spectral.json openapi/
COPY --from=docbuilder /tmp/static/docs/index.html static/docs/index.html
ARG MAKEFLAGS=-j2
RUN make all bin/lavinmq-debug

# Resulting image with minimal layers
FROM ubuntu:22.04
RUN apt-get update && \
    apt-get install -y libssl3 libevent-2.1-7 libevent-pthreads-2.1-7 ca-certificates && \
    rm -rf /var/lib/apt/lists/* /var/cache/debconf/* /var/log/*
COPY --from=builder /tmp/bin/* /usr/bin/
COPY entrypoint.sh /usr/bin/
EXPOSE 5672 15672 5671 15671
VOLUME /var/lib/lavinmq
WORKDIR /var/lib/lavinmq
ENV GC_UNMAP_THRESHOLD=1
HEALTHCHECK CMD ["/usr/bin/lavinmqctl", "status"]
ENTRYPOINT ["entrypoint.sh"]
CMD ["-b", "0.0.0.0", "--guest-only-loopback=false"]
