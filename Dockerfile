# syntax=docker/dockerfile:1
#
# Generic bootstrap image for the TrueForge harness on Tinfoil Containers.
#
# Public software only: TrueForge (@truefoundry/trueforge) from npm, Caddy,
# git and an ssh client, plus bootstrap.sh. Everything that is PHIL's —
# configure.mjs, the agent instructions, the Caddy/start scripts — is fetched
# at boot from the PRIVATE customer-updater repo (apps/agent/harness) over a
# read-only deploy key held in Tinfoil's secrets vault, so no proprietary
# source is in this public image. See bootstrap.sh.
FROM caddy:2 AS caddy

# TrueForge's better-sqlite3 is native; build node_modules in a toolchain
# stage and copy the result into the slim runtime (same base → ABI matches).
FROM node:22-bookworm-slim AS deps
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

FROM node:22-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client libcap2-bin \
 && rm -rf /var/lib/apt/lists/*
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
# Tinfoil runs workloads with zero Linux capabilities and no-new-privileges;
# the official caddy binary carries cap_net_bind_service as a file capability,
# which the kernel then refuses to exec. We listen on an unprivileged port, so
# strip it (same fix as the dsh image).
RUN setcap -r /usr/bin/caddy && getcap /usr/bin/caddy | grep -q . && exit 1 || true

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json package-lock.json bootstrap.sh ./
RUN chmod +x bootstrap.sh

ENV PORT=8080 \
    TRUEFORGE_PORT=4110 \
    TRUEFORGE_SQLITE_PATH=/data/trueforge.sqlite \
    PHIL_SOURCE_PATH=apps/agent/harness
EXPOSE 8080
CMD ["/app/bootstrap.sh"]
