# Testing Kafka + Ranger Authorization

This guide assumes all services are running (`./start-all.sh`). See [README.md](README.md) for setup instructions.

---

## Quick reference

| Item                  | Value                              |
|-----------------------|------------------------------------|
| Kafka broker          | `localhost:6667` (SASL_PLAINTEXT)  |
| Default client config | `/opt/kafka/config/client.properties` (inside container) |
| Admin user            | `admin / admin-secret` (superuser) |
| Kafka user            | `kafka / kafka-secret` (subject to Ranger policies) |
| Ranger Admin UI       | http://localhost:6080 — `admin / rangerR0cks!` |
| Solr audits           | http://localhost:8983/solr/ranger_audits |
| Kafka service name    | `dev_kafka`                        |

The file [client.properties](client.properties) (volume-mounted at `/opt/kafka/config/client.properties` inside the `ranger-kafka` container) authenticates as the `admin` user.

---

## 1. Topic management (admin user)

### List existing topics

```bash
docker exec ranger-kafka bash -c "
  cd /opt/kafka && \
  bin/kafka-topics.sh --list \
    --bootstrap-server localhost:6667 \
    --command-config config/client.properties
"
```

### Create a topic

```bash
docker exec ranger-kafka bash -c "
  cd /opt/kafka && \
  bin/kafka-topics.sh --create \
    --topic mi-topic \
    --partitions 1 \
    --replication-factor 1 \
    --bootstrap-server localhost:6667 \
    --command-config config/client.properties
"
```

### Describe a topic

```bash
docker exec ranger-kafka bash -c "
  cd /opt/kafka && \
  bin/kafka-topics.sh --describe \
    --topic mi-topic \
    --bootstrap-server localhost:6667 \
    --command-config config/client.properties
"
```

---

## 2. Produce and consume messages (admin user)

### Produce messages (interactive — type a line and press Enter, Ctrl+C to stop)

```bash
docker exec -it ranger-kafka bash -c "
  cd /opt/kafka && \
  bin/kafka-console-producer.sh \
    --bootstrap-server localhost:6667 \
    --topic mi-topic \
    --producer.config config/client.properties
"
```

### Consume messages

```bash
docker exec -it ranger-kafka bash -c "
  cd /opt/kafka && \
  bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:6667 \
    --topic mi-topic \
    --from-beginning \
    --consumer.config config/client.properties
"
```

---

## 3. Test Ranger policy enforcement with the `kafka` user

The `kafka` user exists in the JAAS config but has no default Ranger policies, so access will be denied unless you create one.

### Create a temporary client config for the `kafka` user

```bash
docker exec ranger-kafka bash -c 'cat > /tmp/kafka-client.properties << EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="kafka" password="kafka-secret";
EOF'
```

### Try to produce as `kafka` — should be denied

```bash
docker exec ranger-kafka bash -c "
  cd /opt/kafka && \
  echo 'test' | bin/kafka-console-producer.sh \
    --bootstrap-server localhost:6667 \
    --topic mi-topic \
    --producer.config /tmp/kafka-client.properties
"
```

You should see:
```
org.apache.kafka.common.errors.TopicAuthorizationException: Not authorized to access topics: [mi-topic]
```

### Try to consume as `kafka` — should also be denied

```bash
docker exec ranger-kafka bash -c "
  cd /opt/kafka && \
  timeout 5 bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:6667 \
    --topic mi-topic \
    --from-beginning \
    --consumer.config /tmp/kafka-client.properties
" || true
```

### Grant access via Ranger Admin UI

1. Open http://localhost:6080 → log in as `admin / rangerR0cks!`
2. Navigate to **Access Manager → Resource Based Policies → dev_kafka**
3. Click **Add New Policy**
4. Set:
   - **Topic**: `mi-topic`
   - **User**: `kafka`
   - **Permissions**: `publish`, `consume`, `describe`
5. Save and wait ~30 seconds for the policy to propagate to the broker

### Retry as `kafka` — should now succeed

```bash
# Produce
docker exec ranger-kafka bash -c "
  cd /opt/kafka && \
  echo 'hello-ranger' | bin/kafka-console-producer.sh \
    --bootstrap-server localhost:6667 \
    --topic mi-topic \
    --producer.config /tmp/kafka-client.properties
"

# Consume
docker exec ranger-kafka bash -c "
  cd /opt/kafka && \
  timeout 10 bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:6667 \
    --topic mi-topic \
    --from-beginning \
    --consumer.config /tmp/kafka-client.properties
" || true
```

---

## 4. Verify audit events in Solr

Every Kafka operation (allowed or denied) is audited in Solr. Key fields:

| Field      | Meaning                                    |
|------------|--------------------------------------------|
| `reqUser`  | Who performed the action                   |
| `access`   | Kafka operation (e.g. `publish`, `consume`, `describe`) |
| `resource` | Topic name                                 |
| `result`   | `1` = allowed, `0` = denied                |
| `evtTime`  | Event timestamp                            |

### Query last 20 audit events (most recent first)

```bash
docker exec ranger-solr curl -s \
  "http://localhost:8983/solr/ranger_audits/select?q=*:*&rows=20&sort=evtTime+desc&fl=evtTime,reqUser,access,resource,result&wt=json" \
  | python3 -m json.tool
```

### Filter by user

```bash
docker exec ranger-solr curl -s \
  "http://localhost:8983/solr/ranger_audits/select?q=reqUser:kafka&rows=20&sort=evtTime+desc&fl=evtTime,reqUser,access,resource,result&wt=json" \
  | python3 -m json.tool
```

### Filter denied events only

```bash
docker exec ranger-solr curl -s \
  "http://localhost:8983/solr/ranger_audits/select?q=result:0&rows=20&sort=evtTime+desc&fl=evtTime,reqUser,access,resource,result&wt=json" \
  | python3 -m json.tool
```

---

## 5. End-to-end test flow

This sequence demonstrates a full deny → allow cycle with audit trail:

```bash
# 1. Create a new topic as admin
docker exec ranger-kafka bash -c "cd /opt/kafka && bin/kafka-topics.sh --create --topic test-authz --partitions 1 --replication-factor 1 --bootstrap-server localhost:6667 --command-config config/client.properties"

# 2. Produce a message as admin (to seed the topic)
docker exec ranger-kafka bash -c "echo 'hello-ranger' | cd /opt/kafka && bin/kafka-console-producer.sh --bootstrap-server localhost:6667 --topic test-authz --producer.config config/client.properties"

# 3. Create kafka-user config
docker exec ranger-kafka bash -c 'cat > /tmp/kafka-client.properties << EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="kafka" password="kafka-secret";
EOF'

# 4. Try to consume as kafka user (DENIED — no policy yet)
docker exec ranger-kafka bash -c "cd /opt/kafka && timeout 5 bin/kafka-console-consumer.sh --bootstrap-server localhost:6667 --topic test-authz --from-beginning --consumer.config /tmp/kafka-client.properties" || true

# 5. Check the denied audit event
docker exec ranger-solr curl -s "http://localhost:8983/solr/ranger_audits/select?q=reqUser:kafka+AND+result:0&rows=5&sort=evtTime+desc&fl=evtTime,reqUser,access,resource,result&wt=json" | python3 -m json.tool

# 6. NOW: go to Ranger Admin UI (http://localhost:6080) and add a policy
#    that grants kafka user consume+describe on topic test-authz
#    Wait ~30 seconds for the policy to sync...

# 7. Retry consume as kafka user (ALLOWED now)
docker exec -it ranger-kafka bash -c "cd /opt/kafka && timeout 10 bin/kafka-console-consumer.sh --bootstrap-server localhost:6667 --topic test-authz --from-beginning --consumer.config /tmp/kafka-client.properties"

# 8. Verify the allowed audit event
docker exec ranger-solr curl -s "http://localhost:8983/solr/ranger_audits/select?q=reqUser:kafka+AND+result:1&rows=5&sort=evtTime+desc&fl=evtTime,reqUser,access,resource,result&wt=json" | python3 -m json.tool
```

---

## 6. Useful Ranger Admin UI paths

| Path | Description |
|------|-------------|
| http://localhost:6080/index.html#!/policymanager/resource | All services and policies |
| http://localhost:6080/index.html#!/policymanager/resource/dev_kafka | Kafka (`dev_kafka`) policies |
| http://localhost:6080/index.html#!/policymanager/resource/dev_schema_registry | Schema Registry (`dev_schema_registry`) policies |
| http://localhost:6080/index.html#!/reports/audit/bigData | Audit log viewer |

---

## 7. Schema Registry — testing guide

**Quick reference**

| Item | Value |
|---|---|
| Schema Registry URL | `http://localhost:8081` |
| Kafka bootstrap | `ranger-kafka.example.com:6667` (inside Docker network) |
| Ranger service | `dev_schema_registry` |

### 7.1 Health check

```bash
curl -s http://localhost:8081/subjects
# Expected: [] (empty list, no schemas registered yet)
```

### 7.2 Register a schema (Avro)

```bash
curl -s -X POST http://localhost:8081/subjects/test-topic-value/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{"schema": "{\"type\":\"record\",\"name\":\"TestEvent\",\"fields\":[{\"name\":\"id\",\"type\":\"int\"},{\"name\":\"message\",\"type\":\"string\"}]}"}'
# Expected: {"id":1}
```

### 7.3 List all subjects

```bash
curl -s http://localhost:8081/subjects
# Expected: ["test-topic-value"]
```

### 7.4 Retrieve the registered schema

```bash
curl -s http://localhost:8081/subjects/test-topic-value/versions/latest | python3 -m json.tool
```

### 7.5 Check schema compatibility

```bash
# Register a compatible evolved schema (added optional field)
curl -s -X POST http://localhost:8081/compatibility/subjects/test-topic-value/versions/latest \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{"schema": "{\"type\":\"record\",\"name\":\"TestEvent\",\"fields\":[{\"name\":\"id\",\"type\":\"int\"},{\"name\":\"message\",\"type\":\"string\"},{\"name\":\"extra\",\"type\":[\"null\",\"string\"],\"default\":null}]}"}'
# Expected: {"is_compatible":true}
```

### 7.6 Produce and consume Avro-encoded messages with Schema Registry

The Schema Registry stores the schema; Kafka stores the binary-encoded data.

```bash
# Install the Confluent Python client (run once on your host)
pip install confluent-kafka[avro]
```

Then use this Python script on your host machine:

```python
from confluent_kafka import avro
from confluent_kafka.avro import AvroProducer, AvroConsumer

SCHEMA_STR = '''
{
  "type": "record",
  "name": "TestEvent",
  "fields": [
    {"name": "id",      "type": "int"},
    {"name": "message", "type": "string"}
  ]
}
'''

KAFKA_CONFIG = {
    'bootstrap.servers': 'localhost:6667',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism':    'PLAIN',
    'sasl.username':     'admin',
    'sasl.password':     'admin-secret',
    'schema.registry.url': 'http://localhost:8081',
}

schema = avro.loads(SCHEMA_STR)

# --- Produce ---
producer = AvroProducer(KAFKA_CONFIG, default_value_schema=schema)
producer.produce(topic='test-avro', value={'id': 1, 'message': 'hello from ranger'})
producer.flush()
print('Message produced.')

# --- Consume ---
consumer_cfg = {**KAFKA_CONFIG, 'group.id': 'test-group', 'auto.offset.reset': 'earliest'}
consumer = AvroConsumer(consumer_cfg)
consumer.subscribe(['test-avro'])
msg = consumer.poll(10)
if msg and not msg.error():
    print('Received:', msg.value())
consumer.close()
```

### 7.7 Delete a subject (cleanup)

```bash
curl -s -X DELETE http://localhost:8081/subjects/test-topic-value
# Expected: [1]
```

### 7.8 Verify the _schemas topic in Kafka

Schema Registry persists every schema in the `_schemas` Kafka topic:

```bash
docker exec -it ranger-kafka bash -c "
  cd /opt/kafka && \
  bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:6667 \
    --topic _schemas \
    --from-beginning \
    --timeout-ms 3000 \
    --consumer.config config/client.properties
"
```

### 7.9 Ranger policies for Schema Registry

Ranger can enforce policies on Schema Registry **subjects** and **compatibility** resources.

1. Open http://localhost:6080 → log in as `admin / rangerR0cks!`
2. Go to **Access Manager → Resource Based Policies → dev_schema_registry**
3. Click **Add New Policy** and set:
   - **Subject**: `test-topic-value` (or `*` for all)
   - **User/Group**: the principal to authorize
   - **Permissions**: `CREATE`, `READ`, `UPDATE`, `DELETE`
4. Save — policies apply to the REST API calls to Schema Registry

> **Note:** Confluent Schema Registry does not have a native Ranger plugin installed server-side, so Ranger policies here are stored and visible in the UI but enforcement at the REST-API level requires a proxy layer or a distribution that embeds the Ranger plugin (e.g. Cloudera Schema Registry). The `_schemas` Kafka topic itself **is** protected by the existing `dev_kafka` Ranger policy.
