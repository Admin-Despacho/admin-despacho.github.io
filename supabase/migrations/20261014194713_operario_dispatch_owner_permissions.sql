insert into public.permissions(code) values
  ('carriers.manage'),
  ('drafts.manage_all')
on conflict (code) do nothing;

insert into public.role_permissions(role_code, permission_code) values
  ('OPERARIO_DEPOSITO','routes.create'),
  ('OPERARIO_DEPOSITO','routes.edit'),
  ('OPERARIO_DEPOSITO','routes.publish'),
  ('OPERARIO_DEPOSITO','routes.assign'),
  ('OPERARIO_DEPOSITO','routes.view_all'),
  ('OPERARIO_DEPOSITO','routes.view_own'),
  ('OPERARIO_DEPOSITO','drafts.create'),
  ('OPERARIO_DEPOSITO','drafts.view_own'),
  ('OPERARIO_DEPOSITO','drafts.manage_all'),
  ('OPERARIO_DEPOSITO','requests.create'),
  ('OPERARIO_DEPOSITO','columns.view'),
  ('OPERARIO_DEPOSITO','columns.manage_defaults'),
  ('OPERARIO_DEPOSITO','columns.manage_templates'),
  ('OPERARIO_DEPOSITO','locations.view'),
  ('OPERARIO_DEPOSITO','vehicle_mileage.view'),
  ('OPERARIO_DEPOSITO','vehicle_mileage.enter'),
  ('OPERARIO_DEPOSITO','vehicles.view'),
  ('OPERARIO_DEPOSITO','vehicles.service_manage'),
  ('OPERARIO_DEPOSITO','carriers.manage')
on conflict (role_code, permission_code) do nothing;

create or replace function public.can_manage_draft_of(p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public'
as $$
  select p_owner = auth.uid()
    or public.auth_has_perm('drafts.manage_all')
    or public.auth_has_perm('routes.manage_all_drafts')
    or (public.auth_has_perm('drafts.manage_team') and public.in_my_team(p_owner));
$$;

create or replace function public.can_view_draft_of(p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path = 'public'
as $$
  select public.can_manage_draft_of(p_owner)
    or (public.auth_has_perm('drafts.view_team') and public.in_my_team(p_owner));
$$;

create or replace function public.upsert_carrier(p jsonb)
returns public.carriers
language plpgsql
security definer
set search_path = 'public'
as $$
declare c public.carriers;
begin
  if not (public.auth_has_perm('settings.manage') or public.auth_has_perm('carriers.manage')) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if coalesce(p->>'id', '') = '' or coalesce(p->>'name', '') = '' then
    raise exception 'BAD_CARRIER: id y nombre obligatorios' using errcode = '23514';
  end if;
  if coalesce(p->>'sequence_code', '') !~ '^[0-9]{2}$' then
    raise exception 'BAD_CODE: el código de correlativo son 2 dígitos' using errcode = '23514';
  end if;
  insert into public.carriers(id, name, kind, active, sequence_code, report_group, emails, notes)
  values (
    upper(p->>'id'),
    upper(p->>'name'),
    coalesce(p->>'kind', 'EXTERNO'),
    coalesce((p->>'active')::boolean, true),
    p->>'sequence_code',
    nullif(p->>'report_group', ''),
    coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'emails','[]'::jsonb)) x), '{}'),
    p->>'notes'
  )
  on conflict (id) do update set
    name = excluded.name,
    kind = excluded.kind,
    active = excluded.active,
    sequence_code = excluded.sequence_code,
    report_group = excluded.report_group,
    emails = excluded.emails,
    notes = excluded.notes
  returning * into c;

  insert into public.audit_log(actor_id, action, target_type, target_id, after)
  values (auth.uid(), 'CARRIER_SAVED', 'carrier', c.id, to_jsonb(c));
  return c;
end;
$$;

revoke execute on function public.upsert_carrier(jsonb) from public;
grant execute on function public.upsert_carrier(jsonb) to authenticated;
