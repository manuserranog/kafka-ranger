# Kafka-Ranger-Demo

This repository sets up a Kafka cluster integrated with Apache Ranger 3.0.0-SNAPSHOT for authentication and authorization. It is based on https://github.com/apache/ranger/tree/master/dev-support/ranger-docker and extended with:

- **SASL_PLAINTEXT / PLAIN** authentication on Kafka (port 6667)
- **RangerKafkaAuthorizer** enforcing topic-level access policies
- **Audit events** flowing to Solr (`ranger_audits`)
- **PostgreSQL 12** as the Ranger metadata database
- **UserSync** and **TagSync** services

---

## Services and endpoints

| Service         | URL / Port                               | Credentials              |
|-----------------|------------------------------------------|--------------------------|
| Ranger Admin    | http://localhost:6080                    | admin / rangerR0cks!     |
| Kafka Broker    | localhost:6667 (SASL_PLAINTEXT)          | admin / admin-secret     |
| Solr (audits)   | http://localhost:8983/solr/ranger_audits | —                        |
| ZooKeeper       | localhost:2181                           | —                        |
| PostgreSQL      | localhost:5432                           | rangeradmin / rangeradmin |

Kafka users (defined in `kafka-authentication/kafka_server_jaas.conf`):
- `admin / admin-secret` — superuser (bypasses Ranger policies)
- `kafka / kafka-secret` — regular user, subject to Ranger policies

---

## Quick start (recommended)

Before starting, make sure the Ranger build artifacts exist in `dist/` (see [Build step](#2-build-apache-ranger) below). Then:

```bash
chmod +x start-all.sh && ./start-all.sh
```

The script:
1. Exports the required environment variables (`DOCKER_BUILDKIT`, `COMPOSE_DOCKER_CLI_BUILD`, `RANGER_DB_TYPE=postgres`)
2. Starts all services in detached mode
3. Polls container status and exits with a non-zero code if any container is not running (printing which ones failed)

---

## Full setup from scratch

### 1. Download binary dependencies

```bash
chmod +x download-archives.sh && ./download-archives.sh
```

### 2. Build Apache Ranger

Build Apache Ranger 3.0.0-SNAPSHOT inside a Docker container (requires internet access; may take ~45 min depending on Maven cache):

```bash
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

docker compose -f docker-compose.ranger-base.yml \
               -f docker-compose.ranger-build.yml up
```

Once the build finishes, a `dist/` directory will contain the compiled Ranger artifacts and a `dist/version` file.

### 3. Start all services

```bash
export RANGER_DB_TYPE=postgres

docker compose \
  -f docker-compose.ranger-base.yml \
  -f docker-compose.ranger.yml \
  -f docker-compose.ranger-postgres.yml \
  -f docker-compose.ranger-usersync.yml \
  -f docker-compose.ranger-tagsync.yml \
  -f docker-compose.ranger-kafka.yml \
  up -d
```

Or simply use the convenience script (which sets all env vars automatically):

```bash
./start-all.sh
```

### 4. Access Ranger Admin

Open http://localhost:6080 — credentials: `admin / rangerR0cks!`

The Kafka service is registered as `dev_kafka`. Topic-level policies can be found under **Access Manager → Resource Based Policies → dev_kafka**.

### 5. Bring everything down

```bash
export RANGER_DB_TYPE=postgres

docker compose \
  -f docker-compose.ranger-base.yml \
  -f docker-compose.ranger.yml \
  -f docker-compose.ranger-postgres.yml \
  -f docker-compose.ranger-usersync.yml \
  -f docker-compose.ranger-tagsync.yml \
  -f docker-compose.ranger-kafka.yml \
  down
```

---

## Testing Kafka and Ranger authorization

See [README-kafka-testing.md](README-kafka-testing.md) for a full guide on:
- Producing and consuming messages with `admin` and `kafka` users
- Verifying Ranger policy enforcement (allow / deny)
- Checking audit events in Solr

