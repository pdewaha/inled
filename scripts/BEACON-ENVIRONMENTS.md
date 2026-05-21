# Beacon environments (fixed — do not guess Kong names)

| | **leam** (dev) | **exled** (prod) |
|---|----------------|------------------|
| Compose dir | `~/leam/docker` | `~/exled/docker` |
| Kong (internal, from `db` / pg_net) | `http://leam-kong:8000` | `http://exled-kong:8000` |
| Public API | `https://leam.tauworks.org` | `https://be.exled.app` |
| App links in email | `https://leam.tauworks.org` | `https://be.exled.app` |
| Activity email function (internal) | `http://leam-kong:8000/functions/v1/send-activity-email` | `http://exled-kong:8000/functions/v1/send-activity-email` |
| Edge functions container | `leam-edge-functions` | `exled-edge-functions` |
| Postgres container | `leam-db` | `exled-db` |
| `docker compose exec` service | `db`, `functions` | `db`, `functions` |

**There is no generic `kong` hostname** on this host — only `leam-kong` and `exled-kong`.

## Commands

```bash
# Dev
cd ~/leam/docker && source .env
source /path/to/inled/scripts/beacon-environments.sh && beacon_use_env leam
bash scripts/setup-activity-email-immediate-dispatch.sh

# Prod
cd ~/exled/docker && source .env
source /path/to/inled/scripts/beacon-environments.sh && beacon_use_env exled
bash scripts/setup-activity-email-immediate-dispatch.sh
```

Scripts in `scripts/` auto-detect from `pwd` (`leam` vs `exled` in path) when you run them from the matching `docker` folder.
