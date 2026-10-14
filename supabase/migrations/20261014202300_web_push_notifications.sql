create table if not exists public.push_vapid_config(
  id text primary key,
  public_key text not null,
  private_key text not null,
  created_at timestamptz not null default now()
);
alter table public.push_vapid_config enable row level security;

create table if not exists public.push_subscriptions(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz
);
alter table public.push_subscriptions enable row level security;
create index if not exists push_subscriptions_user_idx on public.push_subscriptions(user_id) where revoked_at is null;

create table if not exists public.push_jobs(
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null unique references public.notifications(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'QUEUED' check(status in ('QUEUED','SENT','ERROR','SKIPPED')),
  attempt_count int not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);
alter table public.push_jobs enable row level security;
create index if not exists push_jobs_status_idx on public.push_jobs(status,created_at);

create or replace function public.push_public_key()
returns text language plpgsql security definer set search_path='public' as $$
declare k text;
begin
  if auth.uid() is null then raise exception 'NO_AUTH' using errcode='42501'; end if;
  select public_key into k from public.push_vapid_config where id='DEFAULT';
  return k;
end; $$;
revoke execute on function public.push_public_key() from public;
grant execute on function public.push_public_key() to authenticated;

create or replace function public.save_push_subscription(p jsonb)
returns public.push_subscriptions language plpgsql security definer set search_path='public' as $$
declare r public.push_subscriptions;
begin
  if auth.uid() is null then raise exception 'NO_AUTH' using errcode='42501'; end if;
  if coalesce(trim(p->>'endpoint'),'')='' or coalesce(trim(p->>'p256dh'),'')='' or coalesce(trim(p->>'auth'),'')='' then
    raise exception 'BAD_SUBSCRIPTION' using errcode='22023';
  end if;
  insert into public.push_subscriptions(user_id,endpoint,p256dh,auth,user_agent,revoked_at,updated_at)
  values(auth.uid(),p->>'endpoint',p->>'p256dh',p->>'auth',nullif(p->>'user_agent',''),null,now())
  on conflict(endpoint) do update set
    user_id=excluded.user_id,p256dh=excluded.p256dh,auth=excluded.auth,user_agent=excluded.user_agent,revoked_at=null,updated_at=now()
  returning * into r;
  return r;
end; $$;
revoke execute on function public.save_push_subscription(jsonb) from public;
grant execute on function public.save_push_subscription(jsonb) to authenticated;

create or replace function public.revoke_push_subscription(p_endpoint text)
returns boolean language plpgsql security definer set search_path='public' as $$
begin
  if auth.uid() is null then raise exception 'NO_AUTH' using errcode='42501'; end if;
  update public.push_subscriptions set revoked_at=now(),updated_at=now()
   where endpoint=p_endpoint and user_id=auth.uid() and revoked_at is null;
  return found;
end; $$;
revoke execute on function public.revoke_push_subscription(text) from public;
grant execute on function public.revoke_push_subscription(text) to authenticated;

create or replace function public.queue_notification_push()
returns trigger language plpgsql security definer set search_path='public' as $$
begin
  if new.type in ('NUEVA_HOJA_PUBLICADA','HOJA_CORREGIDA','REQUEST_CREATED','REQUEST_APPROVED','REQUEST_REJECTED','REQUEST_OBSERVED') then
    insert into public.push_jobs(notification_id,user_id)
    values(new.id,new.user_id)
    on conflict(notification_id) do nothing;
  end if;
  return new;
end; $$;

drop trigger if exists trg_queue_notification_push on public.notifications;
create trigger trg_queue_notification_push
after insert on public.notifications
for each row execute function public.queue_notification_push();

revoke all on public.push_vapid_config from anon, authenticated;
revoke all on public.push_subscriptions from anon, authenticated;
revoke all on public.push_jobs from anon, authenticated;
