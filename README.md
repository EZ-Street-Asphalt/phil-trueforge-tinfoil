# phil-trueforge-tinfoil

Tinfoil Containers configuration and a **generic bootstrap image** for PHIL's
TrueForge agent harness.

Public software only: TrueForge (`@truefoundry/trueforge`) from npm, Caddy,
git. At boot `bootstrap.sh` fetches PHIL's own harness config
(`apps/agent/harness`) from the private customer-updater repo over a read-only
deploy key held in Tinfoil's secrets vault, then starts it. Nothing
proprietary lives here.

See `apps/agent/docs/trueforge-tinfoil-decisions.md` in that repo.
