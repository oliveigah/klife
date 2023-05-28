#!/bin/bash
bash ./stop-kafka.sh
docker-compose -f ./test/compose_files/docker-compose-kafka.yml up --force-recreate