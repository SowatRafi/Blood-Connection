#!/usr/bin/env bash
# Fresh-volume setup creates separate database identities; the API never connects as the owner/superuser.
set -euo pipefail
psql --username "$POSTGRES_USER" --dbname postgres --set=ON_ERROR_STOP=1 \
  --set=migration_password="$BC_MIGRATION_PASSWORD" --set=runtime_password="$BC_RUNTIME_PASSWORD" <<'SQL'
CREATE ROLE blood_connection_migrator LOGIN PASSWORD :'migration_password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE ROLE blood_connection_app LOGIN PASSWORD :'runtime_password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE DATABASE blood_connection OWNER blood_connection_migrator;
CREATE DATABASE blood_connection_test OWNER blood_connection_migrator;
REVOKE ALL ON DATABASE blood_connection,blood_connection_test FROM PUBLIC;
GRANT CONNECT ON DATABASE blood_connection,blood_connection_test TO blood_connection_app;
SQL
for database in blood_connection blood_connection_test; do
  psql --username "$POSTGRES_USER" --dbname "$database" --set=ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
done
