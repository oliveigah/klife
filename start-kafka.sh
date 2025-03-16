#!/bin/bash
VERSION=${1:-"latest"}

bash ./stop-kafka.sh "$VERSION"
docker-compose -f ./test/compose_files/docker-compose-kafka-${VERSION}.yml up --force-recreate
