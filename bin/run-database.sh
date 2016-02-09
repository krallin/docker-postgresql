#!/bin/bash
set -o errexit


PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
command="/usr/lib/postgresql/$PG_VERSION/bin/postgres -D '$DATA_DIRECTORY' -c config_file='$PG_CONF'"


cp "$PG_CONF"{.template,}
sed -i "s:__DATA_DIRECTORY__:${DATA_DIRECTORY}:g" "$PG_CONF"
sed -i "s:__PG_VERSION__:${PG_VERSION}:g" "$PG_CONF"

if [[ "$1" == "--initialize" ]]; then
  chown -R postgres:postgres "$DATA_DIRECTORY"

  su postgres <<COMMANDS
    /usr/lib/postgresql/$PG_VERSION/bin/initdb -D "$DATA_DIRECTORY"
    /etc/init.d/postgresql start
    psql --command "CREATE USER ${USERNAME:-aptible} WITH SUPERUSER PASSWORD '$PASSPHRASE'"
    psql --command "CREATE DATABASE ${DATABASE:-db}"
    /etc/init.d/postgresql stop
COMMANDS

elif [[ "$1" == "--client" ]]; then
  [ -z "$2" ] && echo "docker run -it aptible/postgresql --client postgresql://..." && exit
  psql "$2"

elif [[ "$1" == "--dump" ]]; then
  [ -z "$2" ] && echo "docker run aptible/postgresql --dump postgresql://... > dump.psql" && exit
  # If the file /dump-output exists, write output there. Otherwise, use stdout.
  [ -e /dump-output ] && exec 3>/dump-output || exec 3>&1
  pg_dump "$2" >&3

elif [[ "$1" == "--restore" ]]; then
  [ -z "$2" ] && echo "docker run -i aptible/postgresql --restore postgresql://... < dump.psql" && exit
  # If the file /restore-input exists, read input there. Otherwise, use stdin.
  [ -e /restore-input ] && exec 3</restore-input || exec 3<&0
  psql "$2" <&3

elif [[ "$1" == "--readonly" ]]; then
  echo "Starting PostgreSQL in read-only mode..."
  su postgres -c "$command --default_transaction_read_only=on"

else
  su postgres -c "$command"

fi