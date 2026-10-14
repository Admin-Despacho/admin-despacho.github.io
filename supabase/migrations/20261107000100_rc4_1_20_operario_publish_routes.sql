insert into public.role_permissions(role_code, permission_code)
values ('OPERARIO_DEPOSITO','routes.publish')
on conflict do nothing;

insert into public.audit_log(actor_id, action, target_type, target_id, after)
values (null, 'ROLE_PERMISSION_DEFAULT_SET', 'role', 'OPERARIO_DEPOSITO',
        jsonb_build_object('permission','routes.publish','reason','El Operario Depósito publica sus propias hojas de ruta.'));
