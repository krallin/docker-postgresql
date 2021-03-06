#!/bin/bash
set -o errexit


# shellcheck disable=SC1091
. /usr/bin/utilities.sh

# Defaults, which may be overridden by setting them in the environment
DEFAULT_RUN_DIRECTORY="/var/run/postgresql"
DEFAULT_PORT="5432"


function pg_init_conf () {
  # Set up the PG config files
  PG_CONF="${CONF_DIRECTORY}/main/postgresql.conf"
  cp "$PG_CONF"{.template,}
  sed -i "s:__DATA_DIRECTORY__:${DATA_DIRECTORY}:g" "$PG_CONF"
  sed -i "s:__CONF_DIRECTORY__:${CONF_DIRECTORY}:g" "$PG_CONF"
  sed -i "s:__RUN_DIRECTORY__:${RUN_DIRECTORY:-"$DEFAULT_RUN_DIRECTORY"}:g" "$PG_CONF"
  sed -i "s:__PORT__:${PORT:-"$DEFAULT_PORT"}:g" "$PG_CONF"
  sed -i "s:__PG_VERSION__:${PG_VERSION}:g" "$PG_CONF"

  # Set up a self-signed SSL cert
  mkdir -p "${CONF_DIRECTORY}/ssl"
  cd "${CONF_DIRECTORY}/ssl"
  openssl req -new -newkey rsa:1024 -days 365000 -nodes -x509 -keyout server.key -subj "/CN=PostgreSQL" -out server.crt
  chmod og-rwx server.key
  chown -R postgres:postgres "${CONF_DIRECTORY}/ssl"
}


function pg_init_data () {
  chown -R postgres:postgres "$DATA_DIRECTORY"
  chmod go-rwx "$DATA_DIRECTORY"
}


function pg_run_server () {
  # Run pg! Passthrough options.
  echo "Running PG with options:" "$@"
  sudo -u postgres "/usr/lib/postgresql/$PG_VERSION/bin/postgres" -D "$DATA_DIRECTORY" -c "config_file=$PG_CONF" "$@"
}


if [[ "$1" == "--initialize" ]]; then
  pg_init_conf
  pg_init_data

  sudo -u postgres "/usr/lib/postgresql/$PG_VERSION/bin/initdb" -D "$DATA_DIRECTORY"
  sudo -u postgres /etc/init.d/postgresql start
  sudo -u postgres psql --command "CREATE USER ${USERNAME:-aptible} WITH SUPERUSER PASSWORD '$PASSPHRASE'"
  sudo -u postgres psql --command "CREATE DATABASE ${DATABASE:-db}"
  sudo -u postgres /etc/init.d/postgresql stop

elif [[ "$1" == "--initialize-from" ]]; then
  [ -z "$2" ] && echo "docker run -it aptible/postgresql --initialize-from postgresql://..." && exit 1

  # Force our username to lowercase to avoid confusion
  # http://www.postgresql.org/message-id/4219EA03.8030302@archonet.com
  REPL_USER=${REPLICATION_USERNAME:-"repl_$(pwgen -s 10 | tr '[:upper:]' '[:lower:]')"}
  REPL_PASS=${REPLICATION_PASSPHRASE:-"$(pwgen -s 20)"}

  # The username is double-quoted because it's a name, but the password is single quoted, because it's a string.
  psql "$2" --command "CREATE USER \"$REPL_USER\" REPLICATION LOGIN ENCRYPTED PASSWORD '$REPL_PASS'" > /dev/null

  pg_init_conf
  pg_init_data

  # TODO: We force ssl=true here, but it's not entirely correct to do so. Perhaps Sweetness should be providing this.
  # TODO: Either way, we should respect whatever came in via the original URL..!
  parse_url "$2"
  # shellcheck disable=SC2154
  sudo -u postgres pg_basebackup -D "$DATA_DIRECTORY" -R -d "$protocol$REPL_USER:$REPL_PASS@$host_and_port/$database?ssl=true"

elif [[ "$1" == "--client" ]]; then
  [ -z "$2" ] && echo "docker run -it aptible/postgresql --client postgresql://..." && exit
  url="$2"
  shift
  shift
  psql "$url" "$@"

elif [[ "$1" == "--dump" ]]; then
  [ -z "$2" ] && echo "docker run aptible/postgresql --dump postgresql://... > dump.psql" && exit
  # If the file /dump-output exists, write output there. Otherwise, use stdout.
  # shellcheck disable=SC2015
  [ -e /dump-output ] && exec 3>/dump-output || exec 3>&1
  pg_dump "$2" >&3

elif [[ "$1" == "--restore" ]]; then
  [ -z "$2" ] && echo "docker run -i aptible/postgresql --restore postgresql://... < dump.psql" && exit
  # If the file /restore-input exists, read input there. Otherwise, use stdin.
  # shellcheck disable=SC2015
  [ -e /restore-input ] && exec 3</restore-input || exec 3<&0
  psql "$2" <&3

elif [[ "$1" == "--readonly" ]]; then
  pg_init_conf
  pg_run_server --default_transaction_read_only=on

else
  pg_init_conf
  pg_run_server

fi
