# Build the Cruise Control metrics reporter jar, loaded by every Kafka broker (KubeDB and Confluent images)
FROM eclipse-temurin:21-jdk AS cruise_control
ARG CC_VERSION

# https://github.com/linkedin/cruise-control/releases
RUN set -eux \
    && apt-get update && apt-get install -y --no-install-recommends ca-certificates wget git \
    && wget -O /opt/cc.tar.gz https://github.com/linkedin/cruise-control/archive/refs/tags/${CC_VERSION}.tar.gz \
    && cd /opt \
    && tar xzf cc.tar.gz \
    && mv /opt/cruise-control-* /opt/cruise-control \
    && rm cc.tar.gz

WORKDIR /opt/cruise-control

# Gradle needs a git repository with the version tag to build
RUN set -eux \
    && git config --global user.email root@localhost \
    && git config --global user.name root \
    && git init \
    && git add . \
    && git commit -q -m "Init local repo." \
    && git tag -a ${CC_VERSION} -m "Init local version." \
    && ./gradlew :cruise-control-metrics-reporter:jar \
    && cp cruise-control-metrics-reporter/build/libs/cruise-control-metrics-reporter-${CC_VERSION}.jar /opt/cruise-control-metrics-reporter.jar

FROM alpine

LABEL org.opencontainers.image.source="https://github.com/kubedb/kafka-init-docker"
ARG TARGETOS
ARG TARGETARCH
ARG TIERED_STORAGE_VERSION
ARG JMX_EXPORTER_VERSION

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

# Prometheus JMX exporter agent and Cruise Control metrics reporter, copied into the pod by run.sh
RUN mkdir -p /tmp/jmx_exporter /tmp/libs \
 && wget -O /tmp/jmx_exporter/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar
COPY jmx-exporter-config.yaml /tmp/jmx_exporter/jmx-exporter-config.yaml
COPY --from=cruise_control /opt/cruise-control-metrics-reporter.jar /tmp/libs/cruise-control-metrics-reporter.jar

COPY init-scripts /init-scripts
COPY scripts /tmp/scripts

ENTRYPOINT ["/init-scripts/run.sh"]