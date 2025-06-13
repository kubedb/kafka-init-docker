FROM alpine

LABEL org.opencontainers.image.source https://github.com/kubedb/kafka-init-docker
ARG TARGETOS
ARG TARGETARCH

# Install necessary dependencies
RUN apk add --no-cache
COPY init-scripts /init-scripts
COPY scripts /tmp/scripts

ENTRYPOINT ["/init-scripts/run.sh"]