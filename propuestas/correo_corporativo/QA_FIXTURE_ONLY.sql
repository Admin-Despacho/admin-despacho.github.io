-- SOLO QA, transaccional: igualar el CHECK al vigente en producción V6; QA había sido revertido a V4.28.
ALTER TABLE public.profiles DROP CONSTRAINT profiles_disabled_modules_valid;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_disabled_modules_valid CHECK (disabled_modules <@ '{APROBACIONES,AUDITORIA,CONFIGURACION,DESPACHO,INFORMES,MIS_HOJAS,USUARIOS,COMERCIAL}'::text[]);
