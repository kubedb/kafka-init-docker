FROM alpine

LABEL org.opencontainers.image.source="https://github.com/kubedb/kafka-init-docker"
ARG TARGETOS
ARG TARGETARCH
ARG TIERED_STORAGE_VERSION

# Install necessary dependencies
RUN apk add --no-cache wget curl jq

RUN wget -P /tmp https://github.com/Aiven-Open/tiered-storage-for-apache-kafka/releases/download/v${TIERED_STORAGE_VERSION}/core-${TIERED_STORAGE_VERSION}.tgz \
 && tar -xvzf /tmp/core-${TIERED_STORAGE_VERSION}.tgz -C /tmp \
 && mkdir -p /tmp/plugin/core && mv /tmp/core-${TIERED_STORAGE_VERSION}/*.jar /tmp/plugin/core

RUN wget -P /tmp https://github.com/Aiven-Open/tiered-storage-for-apache-kafka/releases/download/v${TIERED_STORAGE_VERSION}/gcs-${TIERED_STORAGE_VERSION}.tgz \
 && tar -xvzf /tmp/gcs-${TIERED_STORAGE_VERSION}.tgz -C /tmp \
 && mkdir -p /tmp/plugin/gcs && mv /tmp/gcs-${TIERED_STORAGE_VERSION}/*.jar /tmp/plugin/gcs

RUN wget -P /tmp https://github.com/Aiven-Open/tiered-storage-for-apache-kafka/releases/download/v${TIERED_STORAGE_VERSION}/azure-${TIERED_STORAGE_VERSION}.tgz \
 && tar -xvzf /tmp/azure-${TIERED_STORAGE_VERSION}.tgz -C /tmp \
 && mkdir -p /tmp/plugin/azure && mv /tmp/azure-${TIERED_STORAGE_VERSION}/*.jar /tmp/plugin/azure

RUN wget -P /tmp https://github.com/Aiven-Open/tiered-storage-for-apache-kafka/releases/download/v${TIERED_STORAGE_VERSION}/s3-${TIERED_STORAGE_VERSION}.tgz \
 && tar -xvzf /tmp/s3-${TIERED_STORAGE_VERSION}.tgz -C /tmp \
 && mkdir -p /tmp/plugin/s3 &&  mv /tmp/s3-${TIERED_STORAGE_VERSION}/*.jar /tmp/plugin/s3

RUN wget -P /tmp https://github.com/Aiven-Open/tiered-storage-for-apache-kafka/releases/download/v${TIERED_STORAGE_VERSION}/filesystem-${TIERED_STORAGE_VERSION}.tgz \
 && tar -xvzf /tmp/filesystem-${TIERED_STORAGE_VERSION}.tgz -C /tmp \
 && mkdir -p /tmp/plugin/local &&  mv /tmp/filesystem-${TIERED_STORAGE_VERSION}/*.jar /tmp/plugin/local

COPY init-scripts /init-scripts
COPY scripts /tmp/scripts

ENTRYPOINT ["/init-scripts/run.sh"]