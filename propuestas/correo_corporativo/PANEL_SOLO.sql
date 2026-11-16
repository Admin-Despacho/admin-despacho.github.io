BEGIN;
CREATE TABLE public.com_mail_settings(id int PRIMARY KEY CHECK(id=1),copies text[] NOT NULL DEFAULT '{}',changed_by uuid,changed_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.com_mail_settings(id) VALUES(1);
ALTER TABLE public.com_mail_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.com_mail_settings FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.com_mail_settings TO service_role;
CREATE FUNCTION public._comm_mail_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(public._com_admin(),false) AND EXISTS(SELECT 1 FROM auth.sessions s WHERE s.user_id=auth.uid() AND s.id::text=auth.jwt()->>'session_id' AND (s.not_after IS NULL OR s.not_after>now()));
$$;
REVOKE ALL ON FUNCTION public._comm_mail_admin() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.com_mail_settings_get() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT coalesce(public._comm_mail_admin(),false) THEN RAISE EXCEPTION 'FORBIDDEN' USING errcode='42501';END IF;
 RETURN (SELECT jsonb_build_object('copies',s.copies,'author_always',true,'history','[]'::jsonb) FROM public.com_mail_settings s WHERE id=1);END;$$;
CREATE FUNCTION public.com_mail_settings_set(p_copies text[]) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v text[];oldv text[];
BEGIN IF NOT coalesce(public._comm_mail_admin(),false) THEN RAISE EXCEPTION 'FORBIDDEN' USING errcode='42501';END IF;
 SELECT coalesce(array_agg(DISTINCT lower(btrim(x)) ORDER BY lower(btrim(x))),'{}') INTO v FROM unnest(coalesce(p_copies,'{}')) x WHERE btrim(x)<>'';
 IF cardinality(v)>20 OR EXISTS(SELECT 1 FROM unnest(v)x WHERE length(x)>254 OR x!~'^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+\.[^[:space:]<>@,;]+$') THEN RAISE EXCEPTION 'INVALID_EMAIL_LIST';END IF;
 SELECT copies INTO oldv FROM public.com_mail_settings WHERE id=1 FOR UPDATE;
 UPDATE public.com_mail_settings SET copies=v,changed_by=auth.uid(),changed_at=now() WHERE id=1;
 INSERT INTO public.audit_log(actor_id,action,target_type,target_id,before,after) VALUES(auth.uid(),'COM_MAIL_RECIPIENTS_CHANGED','com_mail_settings','1',jsonb_build_object('copies',oldv),jsonb_build_object('copies',v));
 RETURN public.com_mail_settings_get();END;$$;
REVOKE ALL ON FUNCTION public.com_mail_settings_get(),public.com_mail_settings_set(text[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.com_mail_settings_get(),public.com_mail_settings_set(text[]) TO authenticated;
COMMIT;