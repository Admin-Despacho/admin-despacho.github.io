drop policy if exists carriers_authenticated_read on public.carriers;
create policy carriers_authenticated_read
on public.carriers
for select
to authenticated
using (true);
