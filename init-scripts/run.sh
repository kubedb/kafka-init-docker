#!/bin/sh

set -o errexit
set -o nounset
set -o pipefail
# set -o xtrace # Uncomment this line for debugging purposes

cp -r /tmp/scripts/* /opt/kafka/init-scripts

if [[ -n "${NODE_LABEL_KEY}" && -n "${NODE_NAME}" ]]; then
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  APISERVER="https://kubernetes.default.svc"
  CACERT="/var/run/secrets/kubernetes.io/serviceaccount/token/ca.crt"
  RESPONSE=$(curl -s --cacert $CACERT --header "Authorization: Bearer $TOKEN" \
        --header "Accept: application/json" \
        $APISERVER/api/v1/nodes/$NODE_NAME)
  if [ $? -ne 0 ]; then
    echo "Error: Failed to query API server" >&2
    exit 1
  fi
  LABEL_VALUE=$(echo $RESPONSE | jq -r ".metadata.labels.\"$NODE_LABEL_KEY\" // error(\"Label $NODE_LABEL_KEY not found\")")
  # if error returned from here, exit
  if [ $? -ne 0 ]; then
    echo "Error: Label $NODE_LABEL_KEY not found on node $NODENAME" >&2
    exit 1
  fi
  echo "rack.id=$LABEL_VALUE" >> /opt/kafka/init-scripts/rack.properties
  echo "Set rack.id=$LABEL_VALUE for node $NODE_NAME"
fi

echo "Kafka Initializing Done!!"
