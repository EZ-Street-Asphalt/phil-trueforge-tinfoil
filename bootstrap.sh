#!/usr/bin/env bash
#
# Fetch the harness's private pieces at boot, then hand over to them.
#
#   PHIL_SOURCE_REPO         repo to fetch: git ssh URL (default below) or https URL
#   PHIL_SOURCE_REF          branch, tag or commit to check out (default: staging)
#   PHIL_SOURCE_PATH         directory inside the repo holding the harness (default: apps/agent/dsh)
#   PHIL_SOURCE_SSH_KEY_B64  secret: base64 of a READ-ONLY deploy key (ssh transport)
#   PHIL_SOURCE_HTTPS_TOKEN  secret: a read-only token instead (https transport, port 443);
#                            used when set, so hosts without outbound ssh still work
#
# The checked-out directory is expected to provide docker-entrypoint.sh,
# start.sh, Caddyfile(.token), phil.cordis.yml, presets/ and plugins/ — the
# same files the Railway image bakes in. Its node_modules are the public
# packages installed in this image (/app/node_modules), linked in.
#
# While fetching, a placeholder answers on $PORT so the platform's health
# check passes and the boot is observable: /healthz, and /bootlog (the log of
# this script) for callers presenting the bridge key (x-phil-bridge-key).
# If the fetch fails the placeholder stays up with the failure in the log,
# instead of the platform tearing the enclave down with it.
#
# Note on attestation: Tinfoil measures this image and the config, not what
# is fetched here. The fetched code is PHIL's own, pulled over an authenticated
# channel pinned by PHIL_SOURCE_REF; pin a tag or commit for a fixed release.
set -uo pipefail

log=/tmp/bootstrap.log
: > "$log"
exec > >(tee -a "$log") 2>&1

port="${PORT:-8080}"
node -e '
  const http = require("http"), fs = require("fs");
  const key = process.env.DSH_BRIDGE_KEY || "";
  http.createServer((req, res) => {
    const path = req.url.split("?")[0];
    if (path === "/healthz") return res.writeHead(200).end("bootstrapping\n");
    if (path === "/bootlog") {
      if (!key || req.headers["x-phil-bridge-key"] !== key) return res.writeHead(403).end();
      res.writeHead(200, { "content-type": "text/plain" });
      return fs.createReadStream("/tmp/bootstrap.log").pipe(res);
    }
    res.writeHead(503).end("harness is starting\n");
  }).listen(Number(process.argv[1]), "0.0.0.0");
' "$port" &
placeholder=$!
echo "bootstrap: placeholder listening on :$port (pid $placeholder)"

fail() {
  echo "bootstrap: FAILED — $*"
  echo "bootstrap: holding the placeholder up for inspection (/bootlog with the bridge key)"
  wait "$placeholder"
  exit 1
}

repo="${PHIL_SOURCE_REPO:-git@github.com:EZ-Street-Asphalt/customer-updater.git}"
ref="${PHIL_SOURCE_REF:-staging}"
subdir="${PHIL_SOURCE_PATH:-apps/agent/dsh}"

if [[ -n "${PHIL_SOURCE_HTTPS_TOKEN:-}" ]]; then
  # https transport: rewrite a git@ URL and present the token as a header, so
  # it never appears in the remote URL or the log.
  repo="${repo/#git@github.com:/https://github.com/}"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$PHIL_SOURCE_HTTPS_TOKEN" | base64 -w0)"
  unset PHIL_SOURCE_HTTPS_TOKEN
  echo "bootstrap: transport https (token)"
else
  [[ -n "${PHIL_SOURCE_SSH_KEY_B64:-}" ]] || fail "neither PHIL_SOURCE_HTTPS_TOKEN nor PHIL_SOURCE_SSH_KEY_B64 is set"
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  if ! printf '%s' "$PHIL_SOURCE_SSH_KEY_B64" | tr -d '[:space:]' | base64 -d > /root/.ssh/id_ed25519 2>/dev/null \
     || ! grep -q 'PRIVATE KEY' /root/.ssh/id_ed25519; then
    fail "PHIL_SOURCE_SSH_KEY_B64 does not decode to a private key"
  fi
  chmod 600 /root/.ssh/id_ed25519
  echo "bootstrap: key fingerprint $(ssh-keygen -lf /root/.ssh/id_ed25519 2>&1)"
  if ! timeout 30 ssh-keyscan -T 15 -t ed25519,rsa github.com >> /root/.ssh/known_hosts 2>/tmp/keyscan.err || ! [[ -s /root/.ssh/known_hosts ]]; then
    cat /tmp/keyscan.err
    fail "ssh-keyscan github.com got nothing — is outbound tcp/22 allowed? (set PHIL_SOURCE_HTTPS_TOKEN to fetch over 443)"
  fi
  export GIT_SSH_COMMAND="ssh -i /root/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=20"
  echo "bootstrap: transport ssh (deploy key)"
fi

work=/opt/phil
rm -rf "$work" && mkdir -p "$work"
echo "bootstrap: fetching $subdir from ${repo/#https:\/\/*@/https://} @ $ref"
if ! timeout 300 git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$ref" "$repo" "$work/src"; then
  # A commit sha is not a branch: clone shallowly, then check it out.
  rm -rf "$work/src"
  timeout 300 git clone --quiet --filter=blob:none --sparse "$repo" "$work/src" || fail "git clone failed"
  git -C "$work/src" checkout --quiet "$ref" || fail "checkout of $ref failed"
fi
git -C "$work/src" sparse-checkout set "$subdir" || fail "sparse-checkout of $subdir failed"
echo "bootstrap: at $(git -C "$work/src" rev-parse --short HEAD)"

harness="$work/src/$subdir"
[[ -f "$harness/docker-entrypoint.sh" ]] || fail "$subdir has no docker-entrypoint.sh"
chmod +x "$harness"/*.sh
ln -sfn /app/node_modules "$harness/node_modules"
# Credentials are only needed for the fetch.
shred -u /root/.ssh/id_ed25519 2>/dev/null || rm -f /root/.ssh/id_ed25519
unset PHIL_SOURCE_SSH_KEY_B64 GIT_CONFIG_VALUE_0 GIT_SSH_COMMAND

echo "bootstrap: handing over to $subdir/docker-entrypoint.sh"
kill "$placeholder" 2>/dev/null; wait "$placeholder" 2>/dev/null
cd "$harness"
if [[ "${PHIL_HOLD_ON_FAILURE:-1}" != "1" ]]; then
  exec ./docker-entrypoint.sh
fi
# Hold mode (default): the harness runs as a child; if it ever exits, its
# output is in the log and a placeholder takes the port back so the enclave
# stays reachable for diagnosis instead of being torn down.
# Its own process group, so whichever of Caddy/dsh outlived the other can be
# stopped too and the port is free for the placeholder.
setsid ./docker-entrypoint.sh &
harness_pid=$!
wait "$harness_pid"
code=$?
echo "bootstrap: harness exited with status $code"
kill -TERM -- "-$harness_pid" 2>/dev/null; sleep 2; kill -KILL -- "-$harness_pid" 2>/dev/null
node -e '
  const http = require("http"), fs = require("fs");
  const key = process.env.DSH_BRIDGE_KEY || "";
  const srv = http.createServer((req, res) => {
    const path = req.url.split("?")[0];
    if (path === "/healthz") return res.writeHead(200).end("harness exited\n");
    if (path === "/bootlog") {
      if (!key || req.headers["x-phil-bridge-key"] !== key) return res.writeHead(403).end();
      res.writeHead(200, { "content-type": "text/plain" });
      return fs.createReadStream("/tmp/bootstrap.log").pipe(res);
    }
    res.writeHead(503).end("harness exited\n");
  });
  let tries = 0;
  srv.on("error", (e) => { if (e.code === "EADDRINUSE" && tries++ < 40) setTimeout(() => srv.listen(Number(process.argv[1]), "0.0.0.0"), 500); else throw e; });
  srv.listen(Number(process.argv[1]), "0.0.0.0");
' "$port" &
placeholder=$!
fail "harness exited with status $code"
