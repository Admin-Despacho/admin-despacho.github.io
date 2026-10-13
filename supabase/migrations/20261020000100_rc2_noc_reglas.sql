-- OK DESPACHO ONLINE — RC2 (incremental): NOC con consumo único server-side + reglas financieras vigentes obligatorias al publicar.
-- No modifica Cianbox: solo registra el uso de las NOC dentro de OK Despacho.

insert into public.permissions(code) values ('credit_notes.manage') on conflict do nothing;
insert into public.role_permissions(role_code, permission_code) values ('ADMIN','credit_notes.manage') on conflict do nothing;
insert into public.module_permissions(module, permission_code) values ('CONFIGURACION','credit_notes.manage') on conflict do nothing;

-- Huella estable: cliente + comprobante + fecha de emisión (normalizados). No incluye el saldo: aunque el saldo de la NOC
-- cambie entre un Excel y otro, sigue siendo la MISMA NOC (así no se puede volver a usar como si fuera nueva).
create or replace function public.noc_fingerprint(p_client text, p_comp text, p_date text) returns text language sql immutable as $$
  select encode(sha256(convert_to(upper(regexp_replace(coalesce(p_client,''), '\s+', '', 'g')) || '|' || upper(regexp_replace(coalesce(p_comp,''), '\s+', '', 'g')) || '|' || coalesce(p_date,''), 'UTF8')), 'hex');
$$;

create table if not exists public.credit_notes (
  fingerprint text primary key, client_key text not null, comp text not null, issued_date text, original_amount numeric(14,2) not null check (original_amount > 0),
  remaining_amount numeric(14,2) not null check (remaining_amount >= 0),
  status text not null default 'DISPONIBLE' check (status in ('DISPONIBLE','PARCIAL','CONSUMIDA','IGNORADA','RECHAZADA')),
  reason text, decided_by uuid, decided_at timestamptz, created_by uuid, created_at timestamptz not null default now()
);
create table if not exists public.credit_note_applications (
  id uuid primary key default gen_random_uuid(), fingerprint text not null references public.credit_notes(fingerprint), sheet_key text not null, route_id uuid references public.routes(id),
  amount numeric(14,2) not null check (amount > 0), status text not null default 'RESERVED' check (status in ('RESERVED','CONSUMED','RELEASED')),
  op_id text unique, created_by uuid, created_at timestamptz not null default now()
);
create table if not exists public.credit_note_events (
  id bigserial primary key, fingerprint text not null, event text not null check (event in ('ACCEPTED','CONSUMED','RELEASED','IGNORED','REJECTED')),
  amount numeric(14,2), sheet_key text, route_id uuid, actor uuid, at timestamptz not null default now(), detail jsonb
);
alter table public.credit_notes enable row level security; alter table public.credit_note_applications enable row level security; alter table public.credit_note_events enable row level security;
create policy cn_read on public.credit_notes for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('credit_notes.manage'));
create policy cna_read on public.credit_note_applications for select to authenticated using (public.auth_has_perm('routes.create') or public.auth_has_perm('credit_notes.manage'));
create policy cne_read on public.credit_note_events for select to authenticated using (public.auth_has_perm('credit_notes.manage') or public.auth_has_perm('audit.view'));
grant select on public.credit_notes, public.credit_note_applications, public.credit_note_events to authenticated;

create or replace function public._noc_status(rem numeric, orig numeric, cur text) returns text language sql immutable as $$
  select case when cur in ('IGNORADA','RECHAZADA') then cur when rem <= 0.004 then 'CONSUMIDA' when rem < orig - 0.004 then 'PARCIAL' else 'DISPONIBLE' end;
$$;

-- Aceptación EXPLÍCITA del operador para una hoja borrador suya. Saldo CC = piso: el cobro nunca queda por debajo del saldo de la CC.
-- Consumo único: la fila de la NOC se bloquea (FOR UPDATE) y el remanente se descuenta al reservar; un reintento (op_id) no descuenta dos veces.
create or replace function public.apply_credit_note(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare fp text; n public.credit_notes; d public.route_drafts; a public.credit_note_applications; allowed numeric; applied numeric;
        req numeric := (p->>'amount')::numeric; ord numeric := (p->>'order_amount')::numeric; cc numeric := coalesce((p->>'cc_saldo')::numeric, 0);
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce((p->>'accept')::boolean, false) is not true then raise exception 'NOC_NOT_ACCEPTED: la NOC se aplica solo con aceptación explícita' using errcode = '23514'; end if;
  d := public._draft(p->>'sheet_key', true);
  select * into a from public.credit_note_applications where op_id = p->>'op_id';
  if found then select * into n from public.credit_notes where fingerprint = a.fingerprint;
    return jsonb_build_object('fingerprint', a.fingerprint, 'applied', a.amount, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', true); end if;
  if req is null or req <= 0 or ord is null or ord < 0 then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  fp := public.noc_fingerprint(p->>'client_key', p->>'comp', p->>'issued_date');
  insert into public.credit_notes(fingerprint, client_key, comp, issued_date, original_amount, remaining_amount, created_by)
  values (fp, p->>'client_key', p->>'comp', p->>'issued_date', (p->>'original_amount')::numeric, (p->>'original_amount')::numeric, auth.uid()) on conflict (fingerprint) do nothing;
  select * into n from public.credit_notes where fingerprint = fp for update;
  if n.status in ('IGNORADA','RECHAZADA') then raise exception 'NOC_BLOCKED: Administración marcó esta NOC como %', n.status using errcode = '23514'; end if;
  if n.remaining_amount <= 0.004 then raise exception 'NOC_CONSUMED: la NOC ya fue utilizada' using errcode = '23514'; end if;
  allowed := least(n.remaining_amount, greatest(0, ord - greatest(cc, 0)));
  if allowed <= 0.004 then raise exception 'NOC_FLOOR: el saldo de la cuenta corriente (%) es el piso del cobro', cc using errcode = '23514'; end if;
  applied := round(least(req, allowed), 2);
  insert into public.credit_note_applications(fingerprint, sheet_key, amount, op_id, created_by) values (fp, p->>'sheet_key', applied, p->>'op_id', auth.uid());
  update public.credit_notes set remaining_amount = remaining_amount - applied, status = public._noc_status(remaining_amount - applied, original_amount, status) where fingerprint = fp returning * into n;
  insert into public.credit_note_events(fingerprint, event, amount, sheet_key, actor, detail) values (fp, 'ACCEPTED', applied, p->>'sheet_key', auth.uid(), jsonb_build_object('requested', req, 'order_amount', ord, 'cc_saldo', cc));
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'NOC_ACCEPTED', 'credit_note', fp, jsonb_build_object('comp', n.comp, 'applied', applied, 'remaining', n.remaining_amount, 'sheet', p->>'sheet_key'));
  return jsonb_build_object('fingerprint', fp, 'applied', applied, 'remaining', n.remaining_amount, 'status', n.status, 'repeated', false);
end; $$;

-- Libera aplicaciones reservadas (deshacer, borrador eliminado, hoja cancelada o NOC bloqueada por Admin): el remanente vuelve
create or replace function public._release_noc(p_where text, p_value text, p_reason text) returns int language plpgsql security definer set search_path = public as $$
declare a record; n int := 0;
begin
  for a in execute format('select * from public.credit_note_applications where status in (''RESERVED'',''CONSUMED'') and %I = $1 for update', p_where) using p_value loop
    update public.credit_note_applications set status = 'RELEASED' where id = a.id;
    update public.credit_notes set remaining_amount = least(original_amount, remaining_amount + a.amount), status = public._noc_status(least(original_amount, remaining_amount + a.amount), original_amount, status) where fingerprint = a.fingerprint;
    insert into public.credit_note_events(fingerprint, event, amount, sheet_key, route_id, actor, detail) values (a.fingerprint, 'RELEASED', a.amount, a.sheet_key, a.route_id, auth.uid(), jsonb_build_object('reason', p_reason));
    n := n + 1;
  end loop;
  return n;
end; $$;
revoke execute on function public._release_noc(text, text, text) from public, anon, authenticated;
create or replace function public.release_credit_note(p_sheet_key text, p_fingerprint text) returns int language plpgsql security definer set search_path = public as $$
declare a record; n int := 0;
begin
  if not public.auth_has_perm('routes.create') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  perform public._draft(p_sheet_key, false);
  for a in select * from public.credit_note_applications where sheet_key = p_sheet_key and fingerprint = p_fingerprint and status = 'RESERVED' for update loop
    update public.credit_note_applications set status = 'RELEASED' where id = a.id;
    update public.credit_notes set remaining_amount = least(original_amount, remaining_amount + a.amount), status = public._noc_status(least(original_amount, remaining_amount + a.amount), original_amount, status) where fingerprint = a.fingerprint;
    insert into public.credit_note_events(fingerprint, event, amount, sheet_key, actor, detail) values (a.fingerprint, 'RELEASED', a.amount, a.sheet_key, auth.uid(), '{"reason":"deshacer"}');
    n := n + 1;
  end loop;
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'NOC_RELEASED', 'credit_note', p_fingerprint, jsonb_build_object('sheet', p_sheet_key, 'n', n));
  return n;
end; $$;
-- Administración: ignorar o rechazar una NOC (con motivo). Libera lo reservado en borradores; lo consumido en hojas publicadas queda como historial.
create or replace function public.decide_credit_note(p_fingerprint text, p_decision text, p_reason text) returns public.credit_notes language plpgsql security definer set search_path = public as $$
declare n public.credit_notes; a record;
begin
  if not public.auth_has_perm('credit_notes.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_decision not in ('IGNORADA','RECHAZADA') or coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá la decisión y el motivo' using errcode = '23514'; end if;
  select * into n from public.credit_notes where fingerprint = p_fingerprint for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  for a in select * from public.credit_note_applications where fingerprint = p_fingerprint and status = 'RESERVED' for update loop
    update public.credit_note_applications set status = 'RELEASED' where id = a.id;
    update public.credit_notes set remaining_amount = least(original_amount, remaining_amount + a.amount) where fingerprint = p_fingerprint;
    insert into public.credit_note_events(fingerprint, event, amount, sheet_key, actor, detail) values (p_fingerprint, 'RELEASED', a.amount, a.sheet_key, auth.uid(), jsonb_build_object('reason', 'NOC ' || p_decision));
  end loop;
  update public.credit_notes set status = p_decision, reason = p_reason, decided_by = auth.uid(), decided_at = now() where fingerprint = p_fingerprint returning * into n;
  insert into public.credit_note_events(fingerprint, event, actor, detail) values (p_fingerprint, case p_decision when 'IGNORADA' then 'IGNORED' else 'REJECTED' end, auth.uid(), jsonb_build_object('reason', p_reason));
  insert into public.audit_log(actor_id, action, target_type, target_id, after) values (auth.uid(), 'NOC_' || p_decision, 'credit_note', p_fingerprint, jsonb_build_object('reason', p_reason));
  return n;
end; $$;
grant execute on function public.apply_credit_note(jsonb), public.release_credit_note(text, text), public.decide_credit_note(text, text, text), public.noc_fingerprint(text, text, text) to authenticated;

-- Al publicar: lo reservado en el borrador queda CONSUMIDO por la hoja. Al cancelar la hoja: se libera.
create or replace function public.trg_noc_on_draft_status() returns trigger language plpgsql security definer set search_path = public as $$
declare a record;
begin
  if new.status = 'PUBLICADA' and old.status = 'BORRADOR' then
    for a in update public.credit_note_applications set status = 'CONSUMED', route_id = new.route_id where sheet_key = new.client_sheet_key and status = 'RESERVED' returning * loop
      insert into public.credit_note_events(fingerprint, event, amount, sheet_key, route_id, actor) values (a.fingerprint, 'CONSUMED', a.amount, a.sheet_key, new.route_id, auth.uid());
    end loop;
  elsif new.status = 'CANCELADA' and old.status in ('BORRADOR','PUBLICADA') then
    perform public._release_noc('sheet_key', new.client_sheet_key, case when old.status = 'PUBLICADA' then 'hoja cancelada' else 'borrador eliminado' end);
  end if;
  return new;
end; $$;
drop trigger if exists noc_on_draft_status on public.route_drafts;
create trigger noc_on_draft_status after update of status on public.route_drafts for each row execute function public.trg_noc_on_draft_status();

-- Reglas financieras: una hoja calculada con una versión vieja de las reglas no se publica (hay que recalcular)
create or replace function public.trg_routes_rules_version() returns trigger language plpgsql as $$
declare cur int;
begin
  if new.sheet_snapshot ? 'rules_version' and new.sheet_snapshot->>'rules_version' is not null then
    select max(version) into cur from public.financial_rules;
    if (new.sheet_snapshot->>'rules_version')::int < cur then raise exception 'RULES_OUTDATED: las reglas financieras cambiaron (v%); recalculá la hoja antes de publicar', cur using errcode = '23514'; end if;
  end if;
  return new;
end; $$;
drop trigger if exists routes_rules_version on public.routes;
create trigger routes_rules_version before insert on public.routes for each row execute function public.trg_routes_rules_version();
