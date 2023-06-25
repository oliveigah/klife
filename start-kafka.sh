#!/bin/bash
bash ./stop-kafka.sh
docker-compose -f ./test/compose_files/docker-compose.yml up --force-recreate