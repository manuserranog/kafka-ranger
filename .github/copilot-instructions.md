# Copilot Instructions — kafka-ranger

## Project overview

Local demo environment that integrates **Apache Kafka** with **Apache Ranger 3.0.0-SNAPSHOT** for topic-level authorization and audit. Based on the upstream `ranger/dev-support/ranger-docker` reference setup, extended with:

- SASL_PLAINTEXT / PLAIN authentication on Kafka (port 6667)
- `RangerKafkaAuthorizer` as Kafka's `authorizer.class.name`
- Audit events written to Solr (`ranger_audits` collection)
- PostgreSQL 12 as Ranger metadata database (instead of MySQL)
- UserSync and TagSync services
- Confluent Schema Registry 7.5.0 integrated as an additional service

---

## Service map

| Container                    | Image / Source                        | Ports          | Role                                          |
|------------------------------|---------------------------------------|----------------|-----------------------------------------------|
| `ranger`                     | Built from `Dockerfile.ranger`        | 6080           | Ranger Admin UI + policy engine               |
| `ranger-kafka`               | Built from `Dockerfile.ranger-kafka`  | 6667           | Kafka broker with Ranger plugin               |
| `ranger-postgres`            | Built from `Dockerfile.ranger-postgres` | 5432         | Ranger metadata DB (PostgreSQL 12)            |
| `ranger-solr`                | Built from `Dockerfile.ranger-solr`   | 8983           | Audit storage (Solr `ranger_audits`)          |
| `ranger-zk`                  | Built from `Dockerfile.ranger-zk`     | 2181           | ZooKeeper                                     |
| `ranger-usersync`            | Built from `Dockerfile.ranger-usersync` | —            | Syncs OS/LDAP users into Ranger               |
| `ranger-tagsync`             | Built from `Dockerfile.ranger-tagsync` | —             | Syncs Atlas tags into Ranger                  |
| `ranger-schema-registry`     | `confluentinc/cp-schema-registry:7.5.0` | 8081         | Confluent Schema Registry                     |
| `ranger-schema-registry-init`| `python:3.11-slim` (one-shot)         | —              | Registers `dev_schema_registry` in Ranger     |

All containers share the Docker network `rangernw`.

---

## Credentials

| Service          | Username / Password                      |
|------------------|------------------------------------------|
| Ranger Admin UI  | `admin / rangerR0cks!`                   |
| Kafka (superuser)| `admin / admin-secret`                   |
| Kafka (regular)  | `kafka / kafka-secret`                   |
| PostgreSQL       | `rangeradmin / rangeradmin`              |

The `admin` Kafka user is a **superuser** (declared in `kafka-authentication/kafka_server_jaas.conf`): it bypasses all Ranger policies entirely. The `kafka` user is subject to Ranger topic policies.

---

## Docker Compose file layout

```
docker-compose.ranger-base.yml       # shared base network + volumes
docker-compose.ranger.yml            # ranger + ranger-zk + ranger-solr
docker-compose.ranger-postgres.yml   # ranger-postgres
docker-compose.ranger-usersync.yml   # ranger-usersync
docker-compose.ranger-tagsync.yml    # ranger-tagsync
docker-compose.ranger-kafka.yml      # ranger-kafka
docker-compose.ranger-schema-registry.yml  # ranger-schema-registry + init sidecar
docker-compose.ranger-build.yml      # one-shot Maven build container
```

`start-all.sh` composes all service files above (except `ranger-build`) and starts them in detached mode, then polls container status.

---

## Build pipeline

### Pre-requisite: build Ranger artifacts (once, ~45 min)

```bash
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1
docker compose -f docker-compose.ranger-base.yml \
               -f docker-compose.ranger-build.yml up
```

This produces `dist/` with all compiled Ranger tarballs and `dist/version`. The version string is read by all other Dockerfiles via `ARG RANGER_VERSION`.

### Normal start (after build)

```bash
./start-all.sh
```

### Bring everything down

```bash
export RANGER_DB_TYPE=postgres
docker compose \
  -f docker-compose.ranger-base.yml \
  -f docker-compose.ranger.yml \
  -f docker-compose.ranger-postgres.yml \
  -f docker-compose.ranger-usersync.yml \
  -f docker-compose.ranger-tagsync.yml \
  -f docker-compose.ranger-kafka.yml \
  -f docker-compose.ranger-schema-registry.yml \
  down
```

---

## Critical distinction: rebuild required vs volume-mounted

**Volume-mounted (changes take effect on container restart — no image rebuild needed):**

| File                                              | Mounted into                                         |
|---------------------------------------------------|------------------------------------------------------|
| `scripts/ranger-kafka-plugin-install.properties`  | `/opt/ranger/ranger-kafka-plugin/install.properties` |
| `scripts/create-ranger-services.py`               | `/home/ranger/scripts/create-ranger-services.py`     |
| `server.properties`                               | `/opt/kafka/config/server.properties`                |
| `client.properties`                               | `/opt/kafka/config/client.properties`                |
| `kafka-authentication/kafka_server_jaas.conf`     | `/opt/kafka/config/kafka_server_jaas.conf`           |
| `scripts/ranger-admin-install-postgres.properties`| `/opt/ranger/admin/install.properties`               |
| `scripts/ranger-schema-registry-register.py`      | `/tmp/ranger-schema-registry-register.py` (init)     |

**Baked into image (requires `docker compose build` + container recreate):**

| File                              | Image rebuilt         |
|-----------------------------------|-----------------------|
| `scripts/ranger-kafka.sh`         | `ranger-kafka`        |
| `scripts/ranger-kafka-setup.sh`   | `ranger-kafka`        |

---

## Key design decisions and non-obvious fixes

### 1. JAAS + Solr audit: the NONE → empty patch

**Problem:** Ranger 3.x `XmlConfigChanger` validates every token in the install template. JAAS-related tokens (`XAAUDIT.JAAS.CLIENT.LOGIN_MODULE_NAME`, etc.) must be present and non-empty, so they are set to the literal string `NONE` in `ranger-kafka-plugin-install.properties`.

**Side effect:** `SolrAuditDestination` reads `NONE` as an actual class name and tries to perform a Kerberos JAAS login against Solr, which fails on a non-Kerberized setup.

**Fix** (in `scripts/ranger-kafka.sh`): After `ranger-kafka-setup.sh` runs and generates `ranger-kafka-audit.xml`, a Python 3 snippet clears `xasecure.audit.jaas.Client.loginModuleName` and `xasecure.audit.jaas.Client.loginModuleControlFlag` from `NONE` to `""` in that XML file. This must happen **after** setup but **before** Kafka starts.

Do NOT remove this Python snippet. Do NOT set those properties to empty in `install.properties` — the installer will fail validation.

### 2. Ranger 3.x requires many additional tokens vs 2.x

`ranger-kafka-plugin-install.properties` must include all token groups present in the Ranger 3.x template:
- `POLICY_CACHE_FILE_PATH`, `CREDENTIAL_PROVIDER_FILE`
- All `XAAUDIT.JAAS.CLIENT.*` tokens (set to `NONE`)
- All `XAAUDIT.ELASTICSEARCH.*` tokens (disabled with `NONE`)
- All `XAAUDIT.AMAZON_CLOUDWATCH.*` tokens (disabled with `NONE`)
- All `XAAUDIT.LOG4J.*` tokens (disabled with `false`/`NONE`)
- Both v2 (`XAAUDIT.SOLR.IS_ENABLED`, `XAAUDIT.SOLR.SOLR_URL`) and v3 (`XAAUDIT.SOLR.ENABLE`, `XAAUDIT.SOLR.URL`) Solr tokens

Missing any token causes `ranger-kafka-setup.sh` to fail with a cryptic `XmlConfigChanger` error.

### 3. ssh-keygen hang in ranger-kafka.sh

The `su -c "ssh-keygen ..."` call uses `-P ''` (empty passphrase) to prevent it from waiting for interactive input. Never remove the `-P ''` flag — without it, the container startup hangs indefinitely.

### 4. RANGER_VERSION env var

All Dockerfiles and compose files use `${RANGER_VERSION}` (read from `dist/version`). The version is currently `3.0.0-SNAPSHOT`. Never hardcode this value in Dockerfiles or compose files.

### 5. Schema Registry uses Kafka superuser

`ranger-schema-registry` connects to Kafka as `admin` (superuser) via `SASL_PLAINTEXT / PLAIN`. This is intentional — it bypasses Ranger Kafka ACLs for the internal `_schemas` topic. Ranger authorization for Schema Registry operates at the REST API level via the `schema-registry` service type in Ranger Admin (`dev_schema_registry`).

**Important:** The Ranger 3.x plugin JAR `ranger-3.0.0-SNAPSHOT-schema-registry-plugin.jar` is an **empty packaging artifact** (no classes). REST-level enforcement only works with HW Schema Registry, not Confluent SR. Policy creation in Ranger for `dev_schema_registry` is for documentation/audit purposes in this demo.

---

## Ranger services registered at startup

`scripts/create-ranger-services.py` runs once on first Ranger Admin boot and idempotently creates:

- `dev_hdfs` — HDFS (placeholder, no Hadoop container in this setup)
- `dev_hive` — Hive (placeholder)
- `dev_kafka` — Kafka broker at `ranger-zk.example.com:2181`
- `dev_knox` — Knox (placeholder)
- `dev_schema_registry` — Schema Registry at `http://ranger-schema-registry.example.com:8081`

This script is **volume-mounted**, so changes take effect without rebuilding the Ranger image.

---

## Common Kafka test commands

All run inside the `ranger-kafka` container. `client.properties` authenticates as `admin`.

```bash
# List topics (admin)
docker exec ranger-kafka bash -c "cd /opt/kafka && bin/kafka-topics.sh --list --bootstrap-server localhost:6667 --command-config config/client.properties"

# Create topic
docker exec ranger-kafka bash -c "cd /opt/kafka && bin/kafka-topics.sh --create --topic mi-topic --partitions 1 --replication-factor 1 --bootstrap-server localhost:6667 --command-config config/client.properties"

# Produce messages (interactive)
docker exec -it ranger-kafka bash -c "cd /opt/kafka && bin/kafka-console-producer.sh --bootstrap-server localhost:6667 --topic mi-topic --producer.config config/client.properties"

# Consume messages
docker exec -it ranger-kafka bash -c "cd /opt/kafka && bin/kafka-console-consumer.sh --bootstrap-server localhost:6667 --topic mi-topic --from-beginning --consumer.config config/client.properties"

# Create kafka-user client config
docker exec ranger-kafka bash -c "cat > /tmp/kafka-client.properties << 'EOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"kafka\" password=\"kafka-secret\";
EOF"

# Test access as kafka user (denied without policy)
docker exec ranger-kafka bash -c "cd /opt/kafka && bin/kafka-topics.sh --list --bootstrap-server localhost:6667 --command-config /tmp/kafka-client.properties"
```

Policy propagation from Ranger to Kafka broker takes ~30 seconds after saving a policy.

---

## Audit verification (Solr)

```bash
# Query Solr for audit events
curl "http://localhost:8983/solr/ranger_audits/select?q=*:*&rows=10&wt=json" | python3 -m json.tool

# Filter by user
curl "http://localhost:8983/solr/ranger_audits/select?q=reqUser:kafka&rows=10&wt=json"

# Filter denied events
curl "http://localhost:8983/solr/ranger_audits/select?q=result:0&rows=10&wt=json"
```

Key audit fields: `reqUser`, `resource`, `action`, `result` (1=allow, 0=deny), `evtTime`, `repoName`.

---

## Debugging tips

- **Container fails to start:** `docker logs <container-name>` — check for `XmlConfigChanger` errors (missing token) or `ClassNotFoundException` (JAAS misconfiguration)
- **Policies not enforced:** Ranger plugin polls Ranger every ~30s. Check `docker logs ranger-kafka | grep -i policy`
- **Audit events missing from Solr:** Verify the JAAS patch ran — look for `"Patched ranger-kafka-audit.xml"` in `docker logs ranger-kafka`
- **ranger-kafka-setup.sh fails:** Usually a missing token in `install.properties`. The error line in the log will say which token
- **Schema Registry init exits non-zero:** Check `docker logs ranger-schema-registry-init` — usually a timing issue (Ranger not ready yet); it can be re-run with `docker compose -f docker-compose.ranger-schema-registry.yml run --rm ranger-schema-registry-init`
