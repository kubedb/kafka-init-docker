#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
# set -o xtrace # Uncomment this line for debugging purposes

# Runs in the "kafka-setup" init container, which uses the database image (KubeDB or Confluent).
# It builds the final broker/controller configuration and formats storage. The main container
# then only starts Kafka (see launch.sh).

. /opt/kafka/init-scripts/lib.sh

export KAFKA_CLUSTER_ID=${KAFKA_CLUSTER_ID:-4L6g3nShT-eMCtK--X86sw}

config_dir=/opt/kafka/config
# KubeDB operator empty directory, shared with the main container
kafka_config_dir="$config_dir/kafkaconfig"
# Final Configuration Path, kafka start will use this configuration
final_config_path="$kafka_config_dir/kafka.properties"
operator_config="$kafka_config_dir/config.properties"
# KubeDB operator configuration files
temp_inline_config="$config_dir/temp-config/inline.properties"
temp_operator_config="$config_dir/temp-config/config.properties"
temp_ssl_config="$config_dir/temp-config/ssl.properties"
temp_clientauth_config="$config_dir/temp-config/clientauth.properties"
# Default configuration files shipped with the image
default_config_dir="$(image_config_dir)"
controller_config="$default_config_dir/controller.properties"
broker_config="$default_config_dir/broker.properties"
server_config="$default_config_dir/server.properties"
# KubeDB Custom configuration files
server_custom_config="$config_dir/custom-config/server.properties"
broker_custom_config="$config_dir/custom-config/broker.properties"
controller_custom_config="$config_dir/custom-config/controller.properties"
custom_log4j_config="$config_dir/custom-config/log4j.properties"
custom_tools_log4j_config="$config_dir/custom-config/tools-log4j.properties"
# Utility variables
kafka_broker_max_id=1000
ID=${HOSTNAME##*-}

# For debug purpose
print_bootstrap_config() {
  debug "--------------- Bootstrap configurations ------------------"
  debug $(cat $1)
  debug "------------------------------------------------------------"
}

# This function deletes the meta.properties for a given node ID and the metadata log directory.
# It creates log directory and metadata log directory if they do not exist.
# Arguments:
#   NODE_ID: ID of the node whose metadata is to be deleted
# Returns:
#   None
delete_cluster_metadata() {
  NODE_ID=$1
  # Create or update the log directory for specific node
  modified_log_dirs=()
  info "Enter for metadata deleting node $NODE_ID"

  IFS=','
  for log_dir in $log_dirs; do
    if [[ ! -d "$log_dir/$NODE_ID" ]]; then
      mkdir -p "$log_dir/$NODE_ID"
      info "Created kafka data directory at $log_dir/$NODE_ID"
    elif [[ -e "$log_dir/$NODE_ID/meta.properties" ]]; then
      info "Deleting old metadata..."
      rm -rf "$log_dir/$NODE_ID/meta.properties"
    fi
    modified_log_dirs+=("$log_dir/$NODE_ID")
  done

  log_dirs=$(IFS=','; echo "${modified_log_dirs[*]}")
}

# Function to update the advertised listeners by modifying BROKER:// listeners adding the hostname prefix
update_advertised_listeners() {
  if [[ -z "$advertised_listeners" ]]; then
    return
  fi

  old_advertised_listeners="$advertised_listeners"

  # Use tr to replace commas with newlines and read into an array
  readarray -t elements < <(echo "$advertised_listeners" | tr ',' '\n')
  # Prefix to append to each element
  prefix=$HOSTNAME
  # Loop through the array and modify elements
  modified_elements=()
  for element in "${elements[@]}"; do
    # Check if the element starts with the excluded prefix
    if [[ "$element" == "BROKER://"* || "$element" == "CONTROLLER://"* ]]; then
      modified_elements+=("${element/\/\//\/\/$prefix.}")
    else
      modified_elements+=("$element")  # Skip modification
    fi
  done
  # Join the modified elements into a string using commas as delimiters
  output_string=$(IFS=','; echo "${modified_elements[*]}")
  advertised_listeners="$output_string"
  # Use sed to replace the line containing "advertised.listeners" with the updated one
  sed -i "s|$old_advertised_listeners|$advertised_listeners|" "$operator_config"
  # Print the modified string
  info "Modified advertised_listeners: $advertised_listeners"
}

process_operator_config() {
  # This script copies the temporary operator configuration file to the operator configuration file
  cp "$temp_operator_config" "$operator_config"
  # If a temporary SSL configuration file exists, it concatenates the contents of the temporary SSL configuration file to operator configuration file.
  if [[ -f "$temp_ssl_config" ]]; then
    cat $temp_ssl_config $operator_config > "$kafka_config_dir/config.properties.updated"
    mv "$kafka_config_dir/config.properties.updated" $operator_config
    cp $temp_ssl_config $kafka_config_dir
  fi

  # and merges the custom configuration files based on the process roles specified in the operator configuration file.
  # The merged configuration file is saved in the Kafka configuration directory and move the file to operator configuration.
  roles=$(grep process.roles "$operator_config" | cut -d'=' -f 2-)
  if [[ $roles = "controller" ]]; then
    /opt/kafka/init-scripts/merge_custom_config.sh $controller_custom_config $operator_config $kafka_config_dir/config.properties.merged
  elif [[ $roles = "broker" ]]; then
    /opt/kafka/init-scripts/merge_custom_config.sh $broker_custom_config $operator_config $kafka_config_dir/config.properties.merged
  else [[ $roles = "broker,controller" || $roles = "controller,broker" ]]
    /opt/kafka/init-scripts/merge_custom_config.sh $server_custom_config $operator_config $kafka_config_dir/config.properties.merged
  fi
  # If a file named $temp_inline_config exists, it merges the file with the operator configuration file(apply config)
  /opt/kafka/init-scripts/merge_custom_config.sh $temp_inline_config $operator_config $kafka_config_dir/config.properties.merged

  # update from env
  exclude_envs=(
    "KAFKA_CLUSTER_ID"
    "KAFKA_USER"
    "KAFKA_PASSWORD"
    "KAFKA_SCRAM_256_USERS"
    "KAFKA_SCRAM_512_USERS"
    "KAFKA_SCRAM_256_PASSWORDS"
    "KAFKA_SCRAM_512_PASSWORDS"
    "KAFKA_JVM_PERFORMANCE_OPTS"
    "KAFKA_JMX_OPTS"
  )

  debug "Converting environment variables to properties file format except excluded envs"
  local envs_config_dir="$kafka_config_dir/config_envs.properties"
  convert_envs_to_properties exclude_envs "$envs_config_dir" "KAFKA_"
  debug "Merging envs configuration with final config"
  /opt/kafka/init-scripts/merge_custom_config.sh $envs_config_dir $operator_config $kafka_config_dir/config.properties.merged
  if [[ -e "$envs_config_dir" ]]; then
    rm "$envs_config_dir"
  fi

  # If a file named $temp_clientauth_config exists, it copies the file to the shared kafka config directory.
  if [[ -f $temp_clientauth_config ]]; then
    cp $temp_clientauth_config $kafka_config_dir
  fi

  # If KAFKA_PASSWORD is not empty,
  # replace the placeholders <KAFKA_USER> and <KAFKA_PASSWORD> in clientauth.properties and operator_config files
  if [[ ${KAFKA_PASSWORD:-} != "" ]]; then
    CLIENTAUTHFILE="$kafka_config_dir/clientauth.properties"
    sed -i "s/\<KAFKA_USER\>/"$KAFKA_USER"/g" $CLIENTAUTHFILE
    sed -i "s/\<KAFKA_PASSWORD\>/"$KAFKA_PASSWORD"/g" $CLIENTAUTHFILE

    sed -i "s/KAFKA_USER\>/"$KAFKA_USER"/g" $operator_config
    sed -i "s/\<KAFKA_PASSWORD\>/"$KAFKA_PASSWORD"/g" $operator_config
  fi

  # Reads operator configuration file line by line and sets the values of the keys as environment variables.
  # The keys in the configuration file are separated from their values by an equal sign (=).
  # The script replaces dots (.) in the keys with underscores (_) to make them valid environment variable names.
  while IFS='=' read -r key value
  do
      key=$(echo "$key" | sed -e 's/\./_/g' -e 's/-/___/g')
      eval ${key}=\${value}
  done < "$operator_config"
  # Set the value of KAFKA_CLUSTER_ID
  export KAFKA_CLUSTER_ID=${KAFKA_CLUSTER_ID:-$cluster_id}
  info "Processed and converted operator configuration file into variables"
}

# It starts the Kafka server with the specified configuration.
# For three different process_roles(broker, controller and combined),
# it deletes the cluster metadata,
# sets the node ID, updates the log directories,
# and formats the storage using kafka-storage script before starting the Kafka server.
update_configuration() {
  debug "** Updating configuration file for $process_roles **"
  old_log_dirs="$log_dirs"
  if [[ "$process_roles" = "controller" ]]; then
    ID=$(( ID + kafka_broker_max_id ))
    delete_cluster_metadata $ID
    echo "node.id=$ID" >> "$operator_config"
    sed -i "s|"^log.dirs=$old_log_dirs"|"log.dirs=$log_dirs"|" "$operator_config"
    merge_properties_first_wins "$operator_config" "$controller_config" > "$final_config_path.updated"
    mv "$final_config_path.updated" "$final_config_path"
  elif [[ "$process_roles" = "broker" ]]; then
    delete_cluster_metadata $ID
    echo "node.id=$ID" >> "$operator_config"
    sed -i "s|"^log.dirs=$old_log_dirs"|"log.dirs=$log_dirs"|" "$operator_config"
    merge_properties_first_wins "$operator_config" "$broker_config" > "$final_config_path.updated"
    mv "$final_config_path.updated" "$final_config_path"
  else [[ "$process_roles" = "broker,controller" || "$process_roles" = "controller,broker" ]]
    delete_cluster_metadata "$ID"
    echo "node.id=$ID" >> "$operator_config"
    sed -i "s|"^log.dirs=$old_log_dirs"|"log.dirs=$log_dirs"|" "$operator_config"
    merge_properties_first_wins "$operator_config" "$server_config" > "$final_config_path.updated"
    mv "$final_config_path.updated" "$final_config_path"
  fi
  # If $process_roles is not controller and /opt/kafka/init-scripts/rack.properties file exists,
  # append or replace rack.id in final_config_path
  if [[ "$process_roles" != "controller" && -f /opt/kafka/init-scripts/rack.properties ]]; then
    if grep -q "^broker.rack=" "$final_config_path"; then
      sed -i "s/^broker.rack=.*/$(grep '^broker.rack=' /opt/kafka/init-scripts/rack.properties)/" "$final_config_path"
    else
      cat /opt/kafka/init-scripts/rack.properties >> "$final_config_path"
    fi
  fi
  # tiered storage backend credentials
  if [[ -n "${AZURE_ACCOUNT_KEY:-}" ]]; then
    sed -i "s|\<AZURE_ACCOUNT_KEY\>|"$AZURE_ACCOUNT_KEY"|g" $final_config_path
  fi
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    sed -i "s|\<AWS_ACCESS_KEY_ID\>|"$AWS_ACCESS_KEY_ID"|g" $final_config_path
  fi
  if [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    sed -i "s|\<AWS_SECRET_ACCESS_KEY\>|"$AWS_SECRET_ACCESS_KEY"|g" $final_config_path
  fi

  info "Updated configuration file by process_roles"
}

copy_custom_log4j_if_exists() {
  # If user has provided custom log4j configuration, it will be used
  if [[ -f "$custom_log4j_config" ]]; then
    debug "** Copying custom log4j configuration **"
    cp "$custom_log4j_config" $kafka_config_dir
  fi
  # If user has provided custom tools-log4j configuration, it will be used
  if [[ -f "$custom_tools_log4j_config" ]]; then
    debug "** Copying custom tools-log4j configuration **"
    cp "$custom_tools_log4j_config" $kafka_config_dir
  fi
}

add_scram_credentials() {
  for (( i = 0; i < 2; i++ )); do
    algo_type="$((256 + i * 256))"
    users_var="KAFKA_SCRAM_${algo_type}_USERS"
    passwords_var="KAFKA_SCRAM_${algo_type}_PASSWORDS"

    users_value="${!users_var:-}"
    passwords_value="${!passwords_var:-}"

    if [[ -n "$users_value" && -n "$passwords_value" ]]; then
      debug "Adding SCRAM-SHA-${algo_type} credentials"
      IFS=',' read -ra users <<< "$users_value"
      IFS=',' read -ra passwords <<< "$passwords_value"
      for index in "${!users[@]}"; do
        if [[ -n "${users[$index]}" && -n "${passwords[$index]:-}" ]]; then
          storage_args+=("--add-scram" "SCRAM-SHA-${algo_type}=[name=${users[$index]},password=${passwords[$index]}]")
        fi
      done
    fi
  done
}

format_storage() {
  storage_args=("--cluster-id" "$KAFKA_CLUSTER_ID" "--config" "$final_config_path" "--ignore-formatted")
  add_scram_credentials
  # TODO(): Add support for dynamic quorum changes
  #  https://cwiki.apache.org/confluence/display/KAFKA/KIP-853%3A+KRaft+Controller+Membership+Changes

  # Use the image's class data sharing archive for the storage tool, if it ships one
  if [[ -f /opt/kafka/storage.jsa ]]; then
    export KAFKA_JVM_PERFORMANCE_OPTS="${KAFKA_JVM_PERFORMANCE_OPTS:-} -XX:SharedArchiveFile=/opt/kafka/storage.jsa"
  fi

  info "** Formatting storage **"
  "$(kafka_tool kafka-storage)" format "${storage_args[@]}"
}

# Confluent's own entrypoint scripts build their configuration from KAFKA_* environment variables, so the
# final configuration is also written as an environment file that launch.sh loads. Properties that can't be
# expressed as such a variable (e.g. confluent.telemetry.exporter._local.*) go to a properties file that
# launch.sh appends after Confluent's configure step.
write_confluent_env() {
  local env_file="$kafka_config_dir/kafka.env"
  local extra_file="$kafka_config_dir/kafka-extra.properties"
  local secrets_dir=/etc/kafka/secrets
  local key value env_key keystore truststore

  : > "$extra_file.tmp"
  {
    write_env CLUSTER_ID "$KAFKA_CLUSTER_ID"

    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      key="${line%%=*}"
      value="${line#*=}"
      # Confluent's configure script exits if a controller-only node has advertised listeners.
      if [[ "$process_roles" == "controller" && "$key" == "advertised.listeners" ]]; then
        continue
      fi
      env_key="$(to_env_key "$key")"
      if [[ "$(from_env_key "$env_key")" == "$key" ]]; then
        write_env "$env_key" "$value"
      else
        echo "$key=$value" >> "$extra_file.tmp"
      fi
    done < "$final_config_path"

    # Confluent's configure script only accepts keystores under /etc/kafka/secrets,
    # with passwords supplied as files.
    keystore=$(get_property "$final_config_path" ssl.keystore.location)
    if [[ -n "$keystore" ]]; then
      cp "$keystore" "$secrets_dir/"
      printf '%s' "$(get_property "$final_config_path" ssl.keystore.password)" > "$secrets_dir/keystore_creds"
      printf '%s' "$(get_property "$final_config_path" ssl.key.password)" > "$secrets_dir/key_creds"
      write_env KAFKA_SSL_KEYSTORE_FILENAME "$(basename "$keystore")"
      write_env KAFKA_SSL_KEYSTORE_CREDENTIALS keystore_creds
      write_env KAFKA_SSL_KEY_CREDENTIALS key_creds
    fi
    truststore=$(get_property "$final_config_path" ssl.truststore.location)
    if [[ -n "$truststore" ]]; then
      cp "$truststore" "$secrets_dir/"
      printf '%s' "$(get_property "$final_config_path" ssl.truststore.password)" > "$secrets_dir/truststore_creds"
      write_env KAFKA_SSL_TRUSTSTORE_FILENAME "$(basename "$truststore")"
      write_env KAFKA_SSL_TRUSTSTORE_CREDENTIALS truststore_creds
    fi
  } > "$env_file.tmp"

  chmod 600 "$env_file.tmp" "$extra_file.tmp"
  mv "$env_file.tmp" "$env_file"
  mv "$extra_file.tmp" "$extra_file"
  info "Wrote Confluent environment file $env_file"
}

# TODO(): Improve this later
export KAFKA_SCRAM_256_USERS=${KAFKA_SCRAM_256_USERS:-${KAFKA_USER:-}}
export KAFKA_SCRAM_256_PASSWORDS=${KAFKA_SCRAM_256_PASSWORDS:-${KAFKA_PASSWORD:-}}

setup_kafka() {
  process_operator_config
  update_advertised_listeners
  update_configuration
  remove_comments_and_sort "$final_config_path"
  copy_custom_log4j_if_exists
  format_storage
  if is_confluent; then
    write_confluent_env
  fi
}

info "** Starting Kafka setup for KubeDB **"
setup_kafka
info "** Kafka setup completed **"
