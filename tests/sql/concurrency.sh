#!/usr/bin/env bash
# Concurrencia real (varias conexiones a la vez). Lo llama run.sh con $PSQL y la base levantada.
PSQL="$1"
$PSQL -d okd -c "create table if not exists tst.alloc(n text)" >/dev/null
for w in 1 2 3 4; do ( for i in $(seq 1 25); do $PSQL -d okd -tA -c "insert into tst.alloc select public.next_route_number_for('UCO')" >/dev/null; done ) & done; wait
$PSQL -d okd -c "insert into tst.results(name, ok, detail) select 'C-06 Concurrencia: 100 correlativos en 4 conexiones simultáneas, sin duplicados', count(*) = 100 and count(distinct n) = 100, count(distinct n)::text || ' distintos' from tst.alloc" >/dev/null
# El test histórico usaba un UUID fijo de un rol legado. Desde RC4 reserve_orders exige routes.create;
# elegir dinámicamente un usuario ACTIVO con ese permiso hace que la prueba mida la carrera real, no autorización.
RACE_USER="$($PSQL -d okd -tA -c "select p.id from public.profiles p where p.status='ACTIVO' and public.user_has_perm(p.id,'routes.create') order by case when p.role='OPERARIO_DEPOSITO' then 0 when p.role='ADMIN' then 1 else 2 end, p.id limit 1")"
[ -n "$RACE_USER" ] || { echo "R-08 setup: no hay usuario activo con routes.create" >&2; exit 2; }
RACE="begin; select set_config('request.jwt.claim.sub','$RACE_USER',true); select set_config('request.jwt.claim.role','authenticated',true); select set_config('request.jwt.claims',json_build_object('iat',extract(epoch from now())::bigint+60)::text,true); set local role authenticated; select pg_sleep(0.2); select public.reserve_orders('RACE-__W__', array['49999']); commit;"
ok=0; for w in 1 2 3 4 5; do ( $PSQL -d okd -c "${RACE//__W__/$w}" >/dev/null 2>&1 && echo WIN ) & done > /tmp/okd_race.txt; wait
wins=$(grep -c WIN /tmp/okd_race.txt)
$PSQL -d okd -c "insert into tst.results(name, ok, detail) select 'R-08 Carrera: 5 sesiones reservan el mismo pedido a la vez y gana una sola', $wins = 1 and (select count(*) from public.order_reservations where order_id = '49999') = 1, '$wins ganadora(s)'" >/dev/null
