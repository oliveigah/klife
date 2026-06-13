#!/bin/bash

mkdir ./ssl/tmp

openssl req -new -x509 -keyout ./ssl/ca.key -out ./ssl/ca.crt -days 3650 -subj '/CN=localhost/OU=klifeclient_protocol/O=klifeclient/L=brazil/C=br' -passin pass:klifeclient -passout pass:klifeclient

keytool -genkey -noprompt \
                 -alias localhost \
				 -dname "CN=localhost, OU=klife_client, O=klife, L=brazil, C=br" \
				 -ext "SAN=DNS:localhost,IP:127.0.0.1" \
				 -keystore ./ssl/localhost.keystore.jks \
				 -keyalg RSA \
				 -storepass klifeclient \
				 -keypass klifeclient \
                 -validity 3650

keytool -keystore ./ssl/localhost.keystore.jks -alias localhost -certreq -file ./ssl/tmp/localhost.csr -storepass klifeclient -keypass klifeclient

# The Subject Alternative Name (SAN) is required for TLS hostname verification.
# CSR extensions are NOT copied into the signed cert by default, so we pass the
# SAN explicitly via -extfile. Without a SAN, clients using verify: :verify_peer
# fail with {bad_cert,{hostname_check_failed,missing_subject_altnames}} on strict
# OTP versions (eg. OTP 26/27).
echo "subjectAltName=DNS:localhost,IP:127.0.0.1" > ./ssl/tmp/localhost.ext

openssl x509 -req -CA ./ssl/ca.crt -CAkey ./ssl/ca.key -in ./ssl/tmp/localhost.csr -out ./ssl/tmp/localhost-ca-signed.crt -days 3650 -CAcreateserial -passin pass:klifeclient -extfile ./ssl/tmp/localhost.ext

keytool -keystore ./ssl/localhost.keystore.jks -alias CARoot -import -noprompt -file ./ssl/ca.crt -storepass klifeclient -keypass klifeclient

keytool -keystore ./ssl/localhost.keystore.jks -alias localhost -import -file ./ssl/tmp/localhost-ca-signed.crt -storepass klifeclient -keypass klifeclient

keytool -keystore ./ssl/localhost.truststore.jks -alias CARoot -import -noprompt -file ./ssl/ca.crt -storepass klifeclient -keypass klifeclient

rm -rf ./ssl/tmp