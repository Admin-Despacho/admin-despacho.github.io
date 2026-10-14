-- RC4.1.3: retirar el rol legado DESPACHO.
-- OPERARIO_DEPOSITO es el rol operativo de depósito vigente.
update public.profiles
set role = 'OPERARIO_DEPOSITO'
where role = 'DESPACHO';

delete from public.role_permissions
where role_code = 'DESPACHO';

delete from public.roles
where code = 'DESPACHO';
