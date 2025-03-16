#!/bin/bash

VERSION=${1:-"latest"}

docker-compose -f ./test/compose_files/docker-compose-kafka-${VERSION}.yml down --volumes
