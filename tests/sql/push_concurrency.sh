#!/usr/bin/env bash
# PUSH-CONC-01: dos ejecuciones de claim_push_jobs A LA VEZ (sesiones PostgreSQL reales) nunca toman el mismo trabajo.
PSQL="$1"; G='e0000000-0000-0000-0000-000000000007'
$PSQL -d okd -c "update public.push_jobs set status='SKIPPED'; insert into public.notifications(user_id, type, title, body) select '$G', 'HOJA_CORREGIDA', 'conc ' || g, 'x' from generate_series(1,6) g;" >/dev/null
( $PSQL -d okd -tA -c "begin; set local role service_role; select id from public.claim_push_jobs(3); select pg_sleep(1.5); commit;" > /tmp/okd_pa.txt 2>&1 ) &
sleep 0.3
( $PSQL -d okd -tA -c "begin; set local role service_role; select id from public.claim_push_jobs(10); commit;" > /tmp/okd_pb.txt 2>&1 ) &
wait
A=$(grep -E '^[0-9a-f-]{36}$' /tmp/okd_pa.txt | sort); B=$(grep -E '^[0-9a-f-]{36}$' /tmp/okd_pb.txt | sort)
NA=$(echo "$A" | grep -c .); NB=$(echo "$B" | grep -c .); DUP=$(comm -12 <(echo "$A") <(echo "$B") | grep -c .)
$PSQL -d okd -c "insert into tst.results(name, ok, detail) values ('PUSH-CONC-01 Dos ejecuciones simultáneas no toman el mismo trabajo (sin notificaciones duplicadas)', $([ "$DUP" -eq 0 ] && [ $((NA+NB)) -eq 6 ] && echo true || echo false), 'A=$NA B=$NB repetidos=$DUP')" >/dev/null

