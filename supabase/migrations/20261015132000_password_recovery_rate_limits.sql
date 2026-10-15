create table if not exists public.password_recovery_limits (
  scope text not null check (scope in ('EMAIL','IP')),
  key_hash text not null,
  window_started_at timestamptz not null default now(),
  request_count integer not null default 1 check (request_count > 0),
  updated_at timestamptz not null default now(),
  primary key (scope, key_hash)
);

alter table public.password_recovery_limits enable row level security;
revoke all on table public.password_recovery_limits from anon, authenticated;

create or replace function public.consume_password_recovery_limit(
  p_scope text,
  p_key_hash text,
  p_window_seconds integer,
  p_max_count integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if p_scope not in ('EMAIL','IP')
     or coalesce(length(p_key_hash),0) < 16
     or p_window_seconds < 1
     or p_max_count < 1 then
    return false;
  end if;

  insert into public.password_recovery_limits(scope,key_hash,window_started_at,request_count,updated_at)
  values(p_scope,p_key_hash,now(),1,now())
  on conflict (scope,key_hash) do update
  set
    window_started_at = case
      when password_recovery_limits.window_started_at < now() - make_interval(secs => p_window_seconds)
      then now()
      else password_recovery_limits.window_started_at
    end,
    request_count = case
      when password_recovery_limits.window_started_at < now() - make_interval(secs => p_window_seconds)
      then 1
      else password_recovery_limits.request_count + 1
    end,
    updated_at = now()
  returning request_count into v_count;

  return v_count <= p_max_count;
end;
$$;

revoke execute on function public.consume_password_recovery_limit(text,text,integer,integer) from public, anon, authenticated;
grant execute on function public.consume_password_recovery_limit(text,text,integer,integer) to service_role;
