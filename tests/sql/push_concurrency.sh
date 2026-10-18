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

# DRVLOC-CONC-01: doble toque SIMULTÁNEO de "+ AGREGAR PARADA" (mismo client_op_id, ids de parada distintos) → UNA sola parada
G='e0000000-0000-0000-0000-000000000007'
RID=$($PSQL -d okd -tA -c "select id from public.routes where sheet_key = 'G2-HOJA'")
VER=$($PSQL -d okd -tA -c "select version from public.routes where id = '$RID'")
CALL="select public.add_internal_stop('$RID', jsonb_build_object('id', gen_random_uuid(), 'stop_type', 'UBICACION_INTERNA', 'internal_location_key', 'SAN_JUAN', 'instructions', 'doble toque'), $VER, 'g2-doble-toque');"
( $PSQL -d okd -tA -c "begin; select tst.u('$G'); set local role authenticated; $CALL select pg_sleep(1); commit;" > /tmp/okd_da.txt 2>&1 ) &
sleep 0.2
( $PSQL -d okd -tA -c "begin; select tst.u('$G'); set local role authenticated; $CALL commit;" > /tmp/okd_db.txt 2>&1 ) &
wait
N=$($PSQL -d okd -tA -c "select count(*) from public.route_stops where route_id = '$RID' and instructions = 'doble toque'")
$PSQL -d okd -c "insert into tst.results(name, ok, detail) values ('DRVLOC-CONC-01 Doble toque simultáneo con el mismo client_op_id → UNA sola parada', $([ "$N" -eq 1 ] && echo true || echo false), 'paradas=$N')" >/dev/null

