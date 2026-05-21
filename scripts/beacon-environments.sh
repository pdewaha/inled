# Beacon: leam = dev, exled = prod. Source from other scripts:
#   source "$(dirname "$0")/beacon-environments.sh"
#   beacon_use_env exled   # or: leam | dev | prod

beacon_use_env() {
  local name="${1:-}"
  case "$name" in
    leam|dev)
      BEACON_ENV=leam
      DOCKER_DIR="${DOCKER_DIR:-$HOME/leam/docker}"
      KONG_HOST=leam-kong
      KONG_INTERNAL_URL=http://leam-kong:8000
      PUBLIC_URL=https://leam.tauworks.org
      APP_URL=https://leam.tauworks.org
      DB_CONTAINER=db
      FUNCTIONS_SERVICE=functions
      CRON_LOG=/var/log/leam-activity-email.log
      ;;
    exled|prod)
      BEACON_ENV=exled
      DOCKER_DIR="${DOCKER_DIR:-$HOME/exled/docker}"
      KONG_HOST=exled-kong
      KONG_INTERNAL_URL=http://exled-kong:8000
      PUBLIC_URL=https://be.exled.app
      APP_URL=https://be.exled.app
      DB_CONTAINER=db
      FUNCTIONS_SERVICE=functions
      CRON_LOG=/var/log/exled-activity-email.log
      ;;
    *)
      echo "Usage: beacon_use_env leam|exled  (aliases: dev|prod)" >&2
      return 1
      ;;
  esac
  export BEACON_ENV DOCKER_DIR KONG_HOST KONG_INTERNAL_URL PUBLIC_URL APP_URL
  export DB_CONTAINER FUNCTIONS_SERVICE CRON_LOG
  export ACTIVITY_EMAIL_FUNCTION_URL="${KONG_INTERNAL_URL}/functions/v1/send-activity-email"
  POSTGRES_DB="${POSTGRES_DB:-postgres}"
  export POSTGRES_DB
}

# Infer from current directory when DOCKER_DIR not set explicitly
beacon_use_env_from_pwd() {
  local pwd="${1:-$(pwd)}"
  if [[ "$pwd" == *exled* ]]; then
    beacon_use_env exled
  elif [[ "$pwd" == *leam* ]]; then
    beacon_use_env leam
  else
    echo "ERROR: cd to ~/leam/docker or ~/exled/docker, or run: beacon_use_env leam|exled" >&2
    return 1
  fi
}
