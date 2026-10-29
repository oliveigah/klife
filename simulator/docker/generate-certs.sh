#!/bin/sh
set -eu

if [ -s /tls/server.pem ] && [ -s /tls/ca.crt ]; then
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj /CN=klife-simulator-ca -keyout /tls/ca.key -out /tls/ca.crt
openssl req -new -newkey rsa:2048 -nodes -subj /CN=kafka1 \
  -keyout /tls/server.key -out /tls/server.csr
printf '%s\n' 'subjectAltName=DNS:kafka1,DNS:kafka2,DNS:kafka3' \
  'extendedKeyUsage=serverAuth' > /tls/server.ext
openssl x509 -req -days 3650 -in /tls/server.csr \
  -CA /tls/ca.crt -CAkey /tls/ca.key -CAcreateserial \
  -extfile /tls/server.ext -out /tls/server.crt
cat /tls/server.key /tls/server.crt > /tls/server.pem
chmod 644 /tls/server.pem /tls/ca.crt
