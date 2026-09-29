# Kafka startup design: one flow for the KubeDB and Confluent images

This document tracks the design of how KubeDB starts Kafka pods, after adding support for Confluent Server
(`confluentinc/cp-server`) next to KubeDB's own Apache Kafka image (`ghcr.io/appscode-images/kafka`).

## Goals

1. Run Confluent Server with every KubeDB feature that works on the KubeDB image (SASL, TLS, custom config,
   rack awareness, monitoring, Cruise Control).
2. Start Confluent Server through Confluent's own entrypoint scripts, so the broker is started the way
   Confluent supports.
3. Keep the KubeDB logic in one place (this repo, `kubedb/kafka-init`), shared by both images, with the same
   scripts and paths. The images differ only where they have to.
4. Never rebuild or rehost Confluent's image (its license doesn't allow redistribution).

## Why not configure Confluent Server from the operator directly

The first version of the Confluent support (kubedb/kafka#221) translated the operator's config into
`KAFKA_*` env vars and let Confluent's image start on its own. That can't work, because most per-pod
logic lived in the KubeDB image's scripts, not in the operator:

- `node.id` comes from the pod ordinal (+1000 for controllers).
- Advertised listeners get the pod hostname prefixed.
- `KAFKA_USER` / `KAFKA_PASSWORD` placeholders in the JAAS config are replaced with the real credentials.
- Storage is formatted with `--add-scram` to create the admin SCRAM user.
- Custom and inline config are merged, the per-node data directory and `broker.rack` are set.

Confluent's entrypoint also exits without `CLUSTER_ID`, and the JMX exporter and Cruise Control reporter
jars were baked into the KubeDB image only.

## Pod layout (Kafka >= 4.0.0, both distributions)

```
initContainers:
  kafka-init    kubedb/kafka-init image   copies scripts, JMX agent, Cruise Control reporter; rack lookup
  kafka-setup   database image            /opt/kafka/init-scripts/setup.sh
containers:
  kafka         database image            /opt/kafka/init-scripts/launch.sh
```

| Volume | Mount path | Contents |
|---|---|---|
| `init-scripts` (emptyDir) | `/opt/kafka/init-scripts` | scripts, `jmx_exporter/`, `libs/`, `rack.properties` |
| `kafkaconfig` (emptyDir) | `/opt/kafka/config/kafkaconfig` | generated config: `kafka.properties`, `clientauth.properties`, `ssl.properties`, `kafka.env`, `kafka-extra.properties` |
| `temp-config` (Secret) | `/opt/kafka/config/temp-config` | operator config (unchanged) |
| `custom-config` (Secret) | `/opt/kafka/config/custom-config` | user config (unchanged) |
| `data` (PVC) | `/var/log/kafka` | data and metadata (unchanged) |
| `confluent-secrets` (emptyDir, memory), Confluent only | `/etc/kafka/secrets` | keystore/truststore copies and password files |

`kafka-setup` gets the main container's env, mounts, security context and resources, plus the user's
podTemplate env for the `kafka` container. Users can override it through a podTemplate init container named
`kafka-setup`.

## Scripts (kafka-init-docker/scripts)

| Script | Runs in | Does |
|---|---|---|
| `lib.sh` | both | logging, env<->property conversion (moved from appscode-images/kafka), distribution helpers |
| `setup.sh` | `kafka-setup` | builds the final config (existing logic), formats storage with SCRAM users, and for Confluent writes `kafka.env` / `kafka-extra.properties` and the TLS files |
| `merge_custom_config.sh` | `kafka-setup` | unchanged, except the `lib.sh` path |
| `launch.sh` | `kafka` | copies client config to the image's config dir, writes kafkactl config, adds the JMX agent (`KAFKA_OPTS`) and Cruise Control reporter (`CLASSPATH`), then starts Kafka |

### Where the two images differ

All differences are behind `KUBEDB_KAFKA_DISTRIBUTION` (set by the operator from
`KafkaVersion.spec.distribution`; it can't start with `KAFKA_`, which both images turn into broker
properties) and the helpers in `lib.sh`.

| | KubeDB image | Confluent image |
|---|---|---|
| Default config dir (`image_config_dir`) | `/opt/kafka/config` | `/etc/kafka` |
| Tool names (`kafka_tool`) | `kafka-storage.sh` | `kafka-storage` |
| Class data sharing archives | `storage.jsa` / `kafka.jsa` used if present | none |
| Start | `kafka-server-start.sh kafka.properties` | `. kafka.env`; Confluent's `configure`; append `kafka-extra.properties`; `ensure`; `launch` |
| Main container env | credentials + distribution | license + distribution only |
| Virtual secrets wrapper | `kafka-setup` and `kafka` | `kafka-setup` only |
| TLS keystores | read from `/var/private/ssl` | copied to `/etc/kafka/secrets` with password files |
| Controller-only nodes | advertised listeners kept | advertised listeners dropped (Confluent's `configure` exits otherwise) |

## Decisions

### D1. Build config and format storage in an init container, for both images
Confluent's entrypoint reads config from env vars, which can't be passed between containers, and formatting
needs Kafka's tools, which the Alpine init image doesn't have. Running `setup.sh` in the database image as an
init container solves both, and doing the same for the KubeDB image keeps one flow. Trade-off: a
container restart (without a pod restart) skips setup and reuses the generated config, which is fine
because config changes always restart the pod.

### D2. Confluent's entrypoint steps run as-is
`launch.sh` runs `/etc/confluent/docker/configure`, `ensure` and `launch`, which is what
`/etc/confluent/docker/run` does, plus one step: appending `kafka-extra.properties` after `configure`.
Some properties can't be written as `KAFKA_*` variables: Confluent's conversion (`_`->`.`, `__`->`_`,
`___`->`-`) can't produce a `._` sequence, e.g. `confluent.telemetry.exporter._local.topic.replicas`
(tested: `KAFKA_A__LOCAL_B` -> `a_local.b`, `KAFKA_C___LOCAL_D` -> `c-local.d`). `setup.sh` sends every
property whose env name doesn't convert back to the same key to that file.

### D3. Storage is formatted before Confluent's `ensure`
Confluent's `ensure` formats without `--add-scram`. `setup.sh` formats first with the SCRAM users;
`ensure` then sees "already formatted" and continues (tested).

### D4. KubeDB's own env vars never reach Confluent's entrypoint
Confluent turns every `KAFKA_*` variable into a broker property, so `KAFKA_USER`/`KAFKA_PASSWORD` would
become `user=`/`password=`. The Confluent main container only gets the license
(`KAFKA_CONFLUENT_LICENSE` -> `confluent.license`) and `KUBEDB_KAFKA_DISTRIBUTION`.

### D5. Moved from appscode-images/kafka to kafka-init
`lib.sh`, `entrypoint.sh`/`setup.sh`/`start.sh` logic (cluster ID default, SCRAM format, JSA use,
server start), the JMX exporter agent and its config, and the Cruise Control metrics reporter build.
The appscode image now only has Kafka, kafkactl, the JSA files (they're generated against that Kafka
build) and the `kafka` user. It's no longer usable standalone with `docker run`; its `CMD` points at
`launch.sh`, which only exists when KubeDB mounts the init scripts.

### D6. Generated files live in the shared `kafkaconfig` emptyDir
`setup.sh` used to write `kafka.properties`, `clientauth.properties` and `ssl.properties` into
`/opt/kafka/config`, which is the image's own directory. That doesn't work from an init container, and
Confluent's image has no `/opt/kafka/config`. They now go to `/opt/kafka/config/kafkaconfig`, and
`launch.sh` copies the client files to the image's config dir, so `/opt/kafka/config/clientauth.properties`
(KubeDB) and `/etc/kafka/clientauth.properties` (Confluent) keep working.

### D7. JMX agent through KAFKA_OPTS, Cruise Control reporter through CLASSPATH
Both images' `kafka-run-class` honour these. `launch.sh` sets them only for the Kafka process, so CLI tools
run with `kubectl exec` don't try to start a second agent on port 56790. Older KubeDB images put the agent
in `EXTRA_ARGS`; `launch.sh` clears it for the KubeDB image so the agent isn't loaded twice.

### D8. Confluent defaults set by the operator
- `confluent.balancer.enable = (spec.cruiseControl == nil)`: Confluent's Self-Balancing Clusters and
  Cruise Control would both move partitions.
- Replication factor `min(3, brokers)` for `confluent.license.topic.replication.factor`,
  `confluent.cluster.link.metadata.topic.replication.factor`, `confluent.balancer.topic.replication.factor`
  and `confluent.telemetry.exporter._local.topic.replicas`. On 1 broker, `_confluent-command`,
  `_confluent-link-metadata` and `_confluent-telemetry-metrics` fail to be created otherwise (tested).

### D9. Kafka version of Confluent catalog entries (apimachinery)
`Kafka.IsVersionGreaterOrEqual` parsed `spec.version` (`confluent-8.3.2`) as semver, which fails, so every
version gate (init containers, quorum bootstrap servers, controller advertised listeners) was false for
Confluent. It now maps `confluent-X.Y.Z` to Apache Kafka `(X-4).Y.0` (Confluent Platform 7.x = Kafka 3.x,
8.x = Kafka 4.x; cp-server 8.3.2 formats with metadata version 4.3). Confluent catalog entries must keep
the `confluent-<CP version>` name.

### D10. Confluent runs as uid 1000
Confluent's image runs as `appuser` (uid 1000), which owns `/etc/kafka` (Confluent's `configure` checks it's
writable) and `/etc/kafka/secrets`. The catalog entry's `securityContext.runAsUser` is 1000.

### D11. awk isn't available in Confluent's image
`setup.sh` merged properties with `awk '!seen[$1]++'`. It's replaced by `merge_properties_first_wins` in
`lib.sh` (pure bash, same output).

## Changes per repo

| Repo (branch) | Changes |
|---|---|
| kubedb/kafka-init-docker (`confluent-distribution`) | `lib.sh` and `launch.sh` added; `setup.sh` formats storage, writes generated files to `kafkaconfig`, writes the Confluent env; Dockerfile builds the Cruise Control reporter and downloads the JMX agent; `run.sh` copies them; this document |
| appscode-images/kafka (`kafka-init-refactor`) | `kafka/scripts/`, `jmx-exporter-config.yaml`, the Cruise Control build stage, `EXTRA_ARGS`/`KAFKA_JMX_OPTS` env and the entrypoint removed |
| kubedb/kafka (`kafka-confluent-license`) | env translation and rack shim from #221 removed; `kafka-setup` init container; main command `launch.sh`; `KUBEDB_KAFKA_DISTRIBUTION`; Confluent license env, secrets volume and defaults (D8); vendored apimachinery patched with D9 |
| kubedb/apimachinery (`kafka-confluent-license`) | D9 |
| kubedb/installer (`kafka-confluent-license`) | `kafka-init` `4.0-v2` -> `4.0-v3` for 4.0.0, 4.2.0 and confluent-8.3.2; Confluent `runAsUser: 1000` |
| kubedb/docs (`kafka-confluent-license`) | "How KubeDB runs Confluent Server" section; version naming note |

## Compatibility and rollout

- The new operator requires the new kafka-init image, for both distributions. Publish it under a new tag
  (`4.0-v3`); don't overwrite `4.0-v2`, which older operators use with their own `setup.sh` flow.
- The new scripts also work with the currently published `ghcr.io/appscode-images/kafka:4.0.0`/`4.2.0`
  images (tested with 4.2.0), so the catalog doesn't need new database images.
- The slimmed appscode image must be published under new tags, because older operators still run
  `/opt/kafka/scripts/entrypoint.sh` from the existing tags.
- `kubedb/kafka-init-docker` branch `restart-fix` ("keep metadata log dir") also changes `setup.sh` and
  isn't merged into master; it will conflict with this branch.
- After the apimachinery PR merges, re-vendor it in kubedb/kafka (the vendor copy is patched locally).
- The installer's generated image lists (`catalog/imagelist.yaml`, export/import scripts) still reference
  `4.0-v2`; regenerate them with the usual catalog tooling.

## Testing done (docker, emulating the pod: kafka-init -> kafka-setup -> kafka with the same mounts)

Configs were generated by the operator's own functions (`setKafkaDefaultConfigOpts`,
`setKafkaRoleBasedOpts`, `setKafkaSecurityOpts`), with SASL enabled, 3 replicas.

| Image | Mode | Result |
|---|---|---|
| `ghcr.io/appscode-images/kafka:4.2.0` (published) | combined | pass |
| `ghcr.io/appscode-images/kafka:4.2.0` (published) | topology (3 controllers + 3 brokers) | pass |
| appscode-images/kafka 4.2.0 built from `kafka-init-refactor` (slimmed) | topology | pass |
| `confluentinc/cp-server:8.3.2` | combined | pass |
| `confluentinc/cp-server:8.3.2` | topology | pass |

Checks: all pods running, topic with RF 3, produce/consume over the BROKER listener, SCRAM user `admin`
exists, 3 quorum voters, JMX exporter serves metrics on 56790, Cruise Control reporter on the classpath,
each broker advertises its own hostname. Confluent also: `_local` property applied, no advertised listeners
on controllers, no replication-factor errors, `/etc/kafka/clientauth.properties` present.

## Not done / open

- Not tested on a real Kubernetes cluster: TLS, custom config, rack awareness, virtual secrets, tiered
  storage (KubeDB image), and a real Confluent license.
- Custom log4j config: Kafka 4.x and Confluent use `log4j2.yaml`; KubeDB still copies `log4j.properties`.
  For Confluent, logging is configured by `KAFKA_LOG4J_ROOT_LOGLEVEL` / `KAFKA_LOG4J_LOGGERS`.
- `kafka.env` holds credentials on the `kafkaconfig` emptyDir (disk-backed, pod-local), like the existing
  generated config files.
- Other callers that exec `*.sh` tools inside the pod (e.g. ops-manager) need `kafka_tool`-style handling
  for the Confluent image.
- kafkactl is only in the KubeDB image.
