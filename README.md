# Kafka-Ranger-Demo

This repository consists of all the important requirements to set up a Kafka broker integrated with Apache Ranger for authorization. It is based on https://github.com/apache/ranger/tree/master/dev-support/ranger-docker

## Architecture

The following services are started together:

| Service | Container | Port | Description |
|---|---|---|---|
| Ranger Admin | `ranger` | 6080 | Policy management UI |
| PostgreSQL | `ranger-postgres` | — | Ranger metadata store |
| ZooKeeper | `ranger-zk` | 2181 | Coordination for Kafka |
| Solr | `ranger-solr` | 8983 | Audit log storage |
| Kafka | `ranger-kafka` | 9092 | Kafka broker with Ranger authorizer |
| UserSync | `ranger-usersync` | — | Syncs OS users into Ranger |
| TagSync | `ranger-tagsync` | — | Syncs tag-based policies into Ranger |

## Prerequisites

- Docker 20.10+ with BuildKit support
- docker-compose v1.29+ (or Docker Compose v2 as `docker compose`)
- The compiled Ranger distribution archives placed in the `dist/` directory

  You can build them with:
  ```
  chmod +x download-archives.sh && ./download-archives.sh
  export DOCKER_BUILDKIT=1
  export COMPOSE_DOCKER_CLI_BUILD=1
  docker-compose -f docker-compose.ranger-base.yml -f docker-compose.ranger-build.yml up
  ```
  Time taken to complete the build may vary (up to an hour), depending on the `${HOME}/.m2` Maven cache.

## Quick start (all services)

Once the `dist/` directory contains the built Ranger artifacts, run the convenience script:

```
chmod +x start-all.sh && ./start-all.sh
```

The script exports the required environment variables (`RANGER_DB_TYPE=postgres`), starts every service in detached mode, and exits with a non-zero status code if any container fails to start.

## Manual startup

```
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1
export RANGER_DB_TYPE=postgres

docker-compose \
  -f docker-compose.ranger-base.yml \
  -f docker-compose.ranger.yml \
  -f docker-compose.ranger-postgres.yml \
  -f docker-compose.ranger-usersync.yml \
  -f docker-compose.ranger-tagsync.yml \
  -f docker-compose.ranger-kafka.yml \
  up -d
```

## Accessing Ranger Admin

Once the stack is up, Ranger Admin is available at:

```
http://localhost:6080
```

Default credentials: **admin / rangerR0cks!**

On first boot, the `dev_kafka` service is automatically registered in Ranger, and the Ranger Kafka plugin on the broker is connected to it for authorization.

## Kafka connection

Kafka listens on **PLAINTEXT port 9092** (exposed on the host as `localhost:9092`).

Example producer/consumer using the standard Kafka tools:

```
# List topics (requires a policy allowing the kafka user)
docker exec ranger-kafka kafka-topics.sh --bootstrap-server ranger-kafka.example.com:9092 --list
```

## Shutdown

```
export RANGER_DB_TYPE=postgres
docker-compose \
  -f docker-compose.ranger-base.yml \
  -f docker-compose.ranger.yml \
  -f docker-compose.ranger-postgres.yml \
  -f docker-compose.ranger-usersync.yml \
  -f docker-compose.ranger-tagsync.yml \
  -f docker-compose.ranger-kafka.yml \
  down
```

