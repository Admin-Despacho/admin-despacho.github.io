do $job$
declare invocation text;
begin
 select replace(command,'/functions/v1/comm-dispatcher','/functions/v1/approved-route-pdf') into strict invocation from cron.job where jobname='okd-comunicaciones-despachador' and command like '%https://uqwilzzeyfuatlmwzxna.supabase.co/functions/v1/comm-dispatcher%';
 perform cron.schedule('okd-pdf-aprobado-pendiente','*/5 * * * *','do $tick$ begin if exists(select 1 from public.daily_dispatch_batches where state=''WAIT_PDF'') then execute '||quote_literal(invocation)||'; end if; end $tick$;');
end $job$;