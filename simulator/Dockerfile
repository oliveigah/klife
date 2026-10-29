FROM docker:28-cli AS docker
FROM elixir:1.19.4-otp-28

COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
RUN apt-get update && apt-get install -y --no-install-recommends cmake openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod SIM_CONTAINER=true MIX_HOME=/opt/mix HEX_HOME=/opt/hex
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY lib ./lib
COPY simulator/mix.exs simulator/mix.lock ./simulator/
WORKDIR /app/simulator
RUN mix deps.get --only prod && mix deps.compile
COPY simulator/config ./config
COPY simulator/lib ./lib
COPY simulator/docker ./docker
RUN mix compile --warnings-as-errors
CMD ["mix", "run", "--no-compile", "--no-deps-check", "--no-halt"]
