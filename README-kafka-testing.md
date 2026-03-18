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
docker exec ranger-kafka bash -c "cat > /tmp/kafka-client.properties << 'EOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"kafka\" password=\"kafka-secret\";
EOF"
```

### Try to list topics as `kafka` — should be denied

```bash
docker exec ranger-kafka bash -c "
  cd /opt/kafka && \
  bin/kafka-topics.sh --list \
    --bootstrap-server localhost:6667 \
    --command-config /tmp/kafka-client.properties
"
```

If there is no policy for `kafka`, the output will contain an error like:
```
org.apache.kafka.common.errors.TopicAuthorizationException: Not authorized to access topics
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
docker exec ranger-kafka bash -c "
  cd /opt/kafka && \
  bin/kafka-topics.sh --list \
    --bootstrap-server localhost:6667 \
    --command-config /tmp/kafka-client.properties
"
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
docker exec ranger-kafka bash -c "cat > /tmp/kafka-client.properties << 'EOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"kafka\" password=\"kafka-secret\";
EOF"

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
| http://localhost:6080/index.html#!/reports/audit/bigData | Audit log viewer |
