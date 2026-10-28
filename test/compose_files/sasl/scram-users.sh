#!/bin/bash
# SCRAM users live in the cluster metadata, not in JAAS, so they are created
# through a running broker. Same user/password as PLAIN.
# 8192 iterations (not Kafka's 4096 default) proves clients read `i` from the server.
# Compose starts this only once every broker is healthy, so there is nothing to retry.
# One call per mechanism: Kafka refuses to alter the same user twice in one request.
set -e

for mechanism in SCRAM-SHA-256 SCRAM-SHA-512; do
  /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:19091 \
    --alter --entity-type users --entity-name klifeusr \
    --add-config "$mechanism=[iterations=8192,password=klifepwd]"
done

# Stay up and report healthy, so `docker compose up --wait` returns only once
# the users exist (older Compose versions can't `wait` on an exited container)
touch /tmp/scram-users-ready
exec sleep infinity
