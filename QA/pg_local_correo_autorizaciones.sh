#!/usr/bin/env bash
# Levanta un PostgreSQL 16 local temporal (puerto 55447) SOLO para pruebas.
set -e
D=/tmp/okd_mail_pg; B=/usr/lib/postgresql/16/bin
if [ -f $D/postmaster.pid ]; then runuser -u postgres -- $B/pg_ctl -D $D -m fast stop >/dev/null 2>&1 || true; fi
rm -rf $D; mkdir -p $D; chown postgres $D
runuser -u postgres -- $B/initdb -D $D -A trust -U postgres --locale=C --encoding=UTF8 >/dev/null
runuser -u postgres -- $B/pg_ctl -D $D -o "-p 55447 -k /tmp -c listen_addresses=127.0.0.1 -c max_connections=60" -l $D/log -w start >/dev/null
echo up
