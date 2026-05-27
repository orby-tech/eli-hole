#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE eli_hole_master;
    CREATE DATABASE eli_hole_slave1;
    CREATE DATABASE eli_hole_slave2;
EOSQL
