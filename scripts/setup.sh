#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
# set -o xtrace # Uncomment this line for debugging purposes

. /opt/kafka/scripts/lib.sh

config_dir=/opt/kafka/config
# Final Configuration Path, kafka start will use this configuration
final_config_path="$config_dir/kafka.properties"
# KubeDB operator empty directory
kafka_config_dir="$config_dir/kafkaconfig"
operator_config="$config_dir/kafkaconfig/config.properties"
# KubeDB operator configuration files
temp_operator_config="$config_dir/temp-config/config.properties"
temp_ssl_config="$config_dir/temp-config/ssl.properties"
temp_clientauth_config="$config_dir/temp-config/clientauth.properties"
# Kafka configuration files from 4.0.0
controller_config="$config_dir/controller.properties"
broker_config="$config_dir/broker.properties"
server_config="$config_dir/server.properties"
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
  # Create or update the metadata log directory
  if [[ ! -d "$metadata_log_dir" ]]; then
    mkdir -p $metadata_log_dir
    info "Created kafka metadata directory at $metadata_log_dir"
  elif [[ -e "$metadata_log_dir/meta.properties" ]]; then
     rm -rf "$metadata_log_dir/meta.properties"
  fi
  # Delete previously configured controller.quorum.voters file
  if [[ -e "$metadata_log_dir/__cluster_metadata-0/quorum-state" ]]; then
     rm -rf "$metadata_log_dir/__cluster_metadata-0/quorum-state"
  fi
  # Add or replace cluster_id to metadata_log_dir/cluster_id
  echo "$KAFKA_CLUSTER_ID" > "$metadata_log_dir/cluster_id"
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
    cat $temp_ssl_config $operator_config > config.properties.updated
    mv config.properties.updated $operator_config
    cp $temp_ssl_config $config_dir
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

  # If a file named $temp_clientauth_config exists, it copies the file to /opt/kafka/config directory.
  if [[ -f $temp_clientauth_config ]]; then
    cp $temp_clientauth_config $config_dir
  fi

  # If KAFKA_PASSWORD is not empty,
  # replace the placeholders <KAFKA_USER> and <KAFKA_PASSWORD> in clientauth.properties and operator_config files
  if [[ $KAFKA_PASSWORD != "" ]]; then
    CLIENTAUTHFILE="$config_dir/clientauth.properties"
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
    cat $operator_config $controller_config | awk -F= '!seen[$1]++' > "$controller_config.updated"
    mv "$controller_config.updated" "$final_config_path"
  elif [[ "$process_roles" = "broker" ]]; then
    delete_cluster_metadata $ID
    echo "node.id=$ID" >> "$operator_config"
    sed -i "s|"^log.dirs=$old_log_dirs"|"log.dirs=$log_dirs"|" "$operator_config"
    cat "$operator_config" "$broker_config" | awk -F'=' '!seen[$1]++' > "$broker_config.updated"
    mv "$broker_config.updated" "$final_config_path"
  else [[ "$process_roles" = "broker,controller" || "$process_roles" = "controller,broker" ]]
    delete_cluster_metadata "$ID"
    echo "node.id=$ID" >> "$operator_config"
    sed -i "s|"^log.dirs=$old_log_dirs"|"log.dirs=$log_dirs"|" "$operator_config"
    cat "$operator_config" "$server_config" | awk -F'=' '!seen[$1]++' > "$server_config.updated"
    mv "$server_config.updated" "$final_config_path"
  fi
  info "Updated configuration file by process_roles"
}

copy_custom_log4j_if_exists() {
  # If user has provided custom log4j configuration, it will be used
  if [[ -f "$custom_log4j_config" ]]; then
    debug "** Copying custom log4j configuration **"
    cp "$custom_log4j_config" $config_dir
  fi
  # If user has provided custom tools-log4j configuration, it will be used
  if [[ -f "$custom_tools_log4j_config" ]]; then
    debug "** Copying custom tools-log4j configuration **"
    cp "$custom_tools_log4j_config" $config_dir
  fi
}

addKafkactlConfig() {
  if [[ "$process_roles" == "controller" ]]; then
    return
  fi
  kafkactl_config_path="/opt/kafka/.config/kafkactl/config.yml"
  mkdir -p "$(dirname "$kafkactl_config_path")"
  cat <<EOL > "$kafkactl_config_path"
contexts:
  default:
    brokers:
      - "localhost:9092"
EOL
  CLIENTAUTHFILE="$config_dir/clientauth.properties"
  if [[ -f "$CLIENTAUTHFILE" ]]; then
    cat <<EOL >> "$kafkactl_config_path"
    sasl:
      enabled: true
      mechanism: plaintext
      username: "$KAFKA_USER"
      password: "$KAFKA_PASSWORD"
EOL
    if grep -Ei "^security\.protocol=sasl_ssl" "$CLIENTAUTHFILE"; then
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

# TODO(): Improve this later
export KAFKA_SCRAM_256_USERS=${KAFKA_SCRAM_256_USERS:-$KAFKA_USER}
export KAFKA_SCRAM_256_PASSWORDS=${KAFKA_SCRAM_256_PASSWORDS:-$KAFKA_PASSWORD}

setup_kafka() {
  process_operator_config
  update_advertised_listeners
  update_configuration
  remove_comments_and_sort "$final_config_path"
  copy_custom_log4j_if_exists
  addKafkactlConfig
}

info "** Starting Kafka setup for KubeDB **"
setup_kafka
info "** Kafka setup completed **"
/opt/kafka/scripts/start.sh "$final_config_path"