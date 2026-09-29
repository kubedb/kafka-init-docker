#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
# set -o xtrace # Uncomment this line for debugging purposes

# Runs as the command of the main "kafka" container. The "kafka-setup" init container has already
# built the configuration and formatted storage, so this only places runtime files and starts Kafka.

init_scripts_dir=/opt/kafka/init-scripts
. "$init_scripts_dir/lib.sh"

kafka_config_dir=/opt/kafka/config/kafkaconfig
final_config_path="$kafka_config_dir/kafka.properties"

# Keep client config where users and tools expect it: /opt/kafka/config for the KubeDB image,
# /etc/kafka for Confluent's. The originals also stay in $kafka_config_dir.
copy_runtime_files() {
  local target
  target="$(image_config_dir)"
  if [[ ! -w "$target" ]]; then
    return
  fi
  for file in clientauth.properties ssl.properties log4j.properties tools-log4j.properties; do
    if [[ -f "$kafka_config_dir/$file" ]]; then
      cp "$kafka_config_dir/$file" "$target/"
    fi
  done
}

add_kafkactl_config() {
  if ! command -v kafkactl >/dev/null 2>&1; then
    return
  fi
  if [[ "$(get_property "$final_config_path" process.roles)" == "controller" ]]; then
    return
  fi
  local kafkactl_config_path="$HOME/.config/kafkactl/config.yml"
  local clientauth_file="$kafka_config_dir/clientauth.properties"
  mkdir -p "$(dirname "$kafkactl_config_path")"
  cat <<EOL > "$kafkactl_config_path"
contexts:
  default:
    brokers:
      - "localhost:9092"
EOL
  if [[ -f "$clientauth_file" ]]; then
    cat <<EOL >> "$kafkactl_config_path"
    sasl:
      enabled: true
      mechanism: plaintext
      username: "${KAFKA_USER:-}"
      password: "${KAFKA_PASSWORD:-}"
EOL
    if grep -qEi "^security\.protocol=sasl_ssl" "$clientauth_file"; then
      cat <<EOL >> "$kafkactl_config_path"
    tls:
      enabled: true
      ca: "/var/private/ssl/ca.crt"
      cert: "/var/private/ssl/tls.crt"
      certKey: "/var/private/ssl/tls.key"
      insecure: false
EOL
    fi
  fi
  echo "current-context: default" >> "$kafkactl_config_path"
}

# JMX exporter agent and Cruise Control metrics reporter, shipped by the init image for both distributions
add_agents() {
  local jmx_agent
  jmx_agent=$(ls "$init_scripts_dir"/jmx_exporter/jmx_prometheus_javaagent-*.jar 2>/dev/null | head -1 || true)
  if [[ -n "$jmx_agent" ]]; then
    export KAFKA_OPTS="${KAFKA_OPTS:+$KAFKA_OPTS }-javaagent:$jmx_agent=56790:$init_scripts_dir/jmx_exporter/jmx-exporter-config.yaml"
  fi
  if [[ -d "$init_scripts_dir/libs" ]]; then
    export CLASSPATH="${CLASSPATH:+$CLASSPATH:}$init_scripts_dir/libs/*"
  fi
}

copy_runtime_files
add_kafkactl_config
add_agents

if is_confluent; then
  info "** Starting Confluent Server **"
  # shellcheck disable=SC1091
  . "$kafka_config_dir/kafka.env"
  # Same steps as /etc/confluent/docker/run, plus appending the properties that can't be set through
  # KAFKA_* variables to the kafka.properties rendered by Confluent's configure script.
  /etc/confluent/docker/configure
  cat "$kafka_config_dir/kafka-extra.properties" >> /etc/kafka/kafka.properties
  /etc/confluent/docker/ensure
  exec /etc/confluent/docker/launch
fi

# Older KubeDB images put the JMX agent in EXTRA_ARGS; clear it so the agent isn't loaded twice.
export EXTRA_ARGS=""
export KAFKA_JMX_OPTS="${KAFKA_JMX_OPTS:--Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false -Djava.rmi.server.hostname=127.0.0.1}"
if [[ -f /opt/kafka/kafka.jsa ]]; then
  export KAFKA_JVM_PERFORMANCE_OPTS="${KAFKA_JVM_PERFORMANCE_OPTS:-} -XX:SharedArchiveFile=/opt/kafka/kafka.jsa"
fi

info "** Starting Kafka Server **"
exec "$(kafka_tool kafka-server-start)" "$final_config_path"
