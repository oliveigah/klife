# Klife

[![ci](https://github.com/oliveigah/klife/actions/workflows/ci.yml/badge.svg)](https://github.com/oliveigah/klife/actions/workflows/ci.yml)

Klife is a Future Proof™ kafka client written in Elixir.

It leverages the [klife_protocol](https://github.com/oliveigah/klife_protocol) implementation of Kafka's wire protocol in order to support newer features.


## TODOS

- Connection System
    - SASL

- Producer System
    - Rename client to client
    - Add default producer and partition as client option
    - Implement test helper functions (assert_produced)
    - Improve input errors handling
    - Accept more versions of the protocol
    - OTEL
    - Improve test coverage

- Consumer System (TBD)

