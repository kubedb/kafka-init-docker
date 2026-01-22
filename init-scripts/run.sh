#!/bin/sh

set -o errexit
set -o nounset
set -o pipefail
# set -o xtrace # Uncomment this line for debugging purposes

cp -r /tmp/scripts/* /opt/kafka/init-scripts
if [[ -n "${TOPOLOGY_KEY:-}" && -n "${NODE_NAME:-}" ]]; then
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  APISERVER="https://kubernetes.default.svc"
  CACERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  RESPONSE=$(curl -s --cacert $CACERT --header "Authorization: Bearer $TOKEN" \
        --header "Accept: application/json" \
        $APISERVER/api/v1/nodes/$NODE_NAME)
  if [ $? -ne 0 ]; then
    echo "Error: Failed to query API server" >&2
    exit 1
  fi
  echo $RESPONSE
  LABEL_VALUE=$(echo $RESPONSE | jq -r ".metadata.labels.\"$TOPOLOGY_KEY\" // error(\"Label $TOPOLOGY_KEY not found\")")
  # if error returned from here, exit
  if [ $? -ne 0 ]; then
    echo "Error: Label $TOPOLOGY_KEY not found on node $NODE_NAME" >&2
    exit 1
  fi
  echo "broker.rack=$LABEL_VALUE" >> /opt/kafka/init-scripts/rack.properties
  echo "Set broker.rack=$LABEL_VALUE for node $NODE_NAME"
fi

# Tiered Storage Plugin Setup
if [[ -n ${TIERED_STORAGE_PROVIDER:-} ]]; then
  cp -r /tmp/plugin/core/*.jar /opt/kafka/libs/tiered-plugins/

  # if the value other than s3, gcs, azure, local, exit with error
  if [[ ! "$TIERED_STORAGE_PROVIDER" =~ ^(s3|gcs|azure|local)$ ]]; then
    echo "Error: Invalid TIERED_STORAGE_PROVIDER value: $TIERED_STORAGE_PROVIDER. Supported values are s3, gcs, azure, local." >&2
    exit 1
  fi
  cp -r /tmp/plugin/${TIERED_STORAGE_PROVIDER}/*.jar /opt/kafka/libs/tiered-plugins/
fi

echo "Kafka Initializing Done!!"
