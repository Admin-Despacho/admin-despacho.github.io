drop policy if exists evidence_read on public.stop_evidence;
create policy evidence_read on public.stop_evidence
for select to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'ADMIN'
      and p.status = 'ACTIVO'
  )
  and public.can_view_route((
    select s.route_id from public.route_stops s where s.id = stop_evidence.stop_id
  ))
);

drop policy if exists delivery_receipts_read on public.delivery_receipts;
create policy delivery_receipts_read on public.delivery_receipts
for select to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'ADMIN'
      and p.status = 'ACTIVO'
  )
  and public.can_view_route(route_id)
);
