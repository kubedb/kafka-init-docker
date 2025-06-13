#!/bin/sh

set -o errexit
set -o nounset
set -o pipefail
# set -o xtrace # Uncomment this line for debugging purposes

cp -r /tmp/scripts/* /opt/kafka/user-scripts

# TODO(): kafka rack id extraction from pod scheduled node using label

echo "Kafka Initializing Done!!"
