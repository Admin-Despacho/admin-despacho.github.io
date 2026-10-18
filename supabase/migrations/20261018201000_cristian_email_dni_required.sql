-- Validaciones de servidor. Solo entrega comercial Cristian Torres.
CREATE OR REPLACE FUNCTION public.set_stop_outcome(p_stop uuid, p_outcome text, p_note text, p_reason text, p_op_id text, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS route_stops
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st public.route_stops; r public.routes; cristian boolean; v_commercial boolean; v_task boolean; v_cuil text; v_email text; v_dni text; v_receipt boolean := false; ev jsonb := coalesce(p_extra->'evidence', '{}'); col jsonb := p_extra->'collection'; loc jsonb; sig bytea;
begin
  select * into st from public.route_stops where id = p_stop;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  r := public._my_route(st.route_id);
  -- Comportamiento por tipo de parada: solo PEDIDO es entrega comercial al cliente (email, Recibido Conforme, cobranza, identidad).
  v_commercial := coalesce(st.stop_type, 'PEDIDO') = 'PEDIDO';
  v_task := st.stop_type = 'TAREA';
  if p_op_id is not null and exists (select 1 from public.stop_outcome_ops where op_id = p_op_id) then return st; end if;
  if r.operational_status <> 'EN_CURSO' then raise exception 'BAD_STATE: iniciá el recorrido o la hoja ya está cerrada' using errcode = '23514'; end if;
  if p_outcome not in ('ENTREGADO','ENTREGA_PARCIAL','NO_ENTREGADO','REPROGRAMAR') then raise exception 'BAD_OUTCOME' using errcode = '22023'; end if;
  if p_outcome = 'ENTREGA_PARCIAL' and coalesce(trim(p_note), '') = '' then raise exception 'NOTE_REQUIRED: entrega parcial exige observación' using errcode = '23514'; end if;
  if p_outcome in ('NO_ENTREGADO','REPROGRAMAR') and coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED: indicá el motivo' using errcode = '23514'; end if;
  cristian := exists (select 1 from public.carriers where id = r.carrier_id and report_group = 'CRISTIAN_TORRES');
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- TAREA: no se exige firma ni receptor como en una entrega comercial (alcanza GPS u observación). El resto, igual que antes.
    if not v_task and (coalesce(trim(ev->>'receiver_name'), '') = '' or coalesce(ev->>'signature_png_b64', '') = '') then raise exception 'EVIDENCE_REQUIRED: nombre del receptor y firma obligatorios' using errcode = '23514'; end if;
    sig := case when coalesce(ev->>'signature_png_b64', '') <> '' then decode(ev->>'signature_png_b64', 'base64') end;
    if cristian and v_commercial then
      v_cuil := regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g');
      if length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
      perform public._register_identity(v_cuil, ev);   -- RC1: DNI en Storage privado
      if not exists (select 1 from public.customer_identity_docs d where d.cuil = v_cuil and (d.storage_path is not null or d.dni_photo is not null)) then
        raise exception 'DNI_REQUIRED: cargá la foto del DNI para el CUIL nuevo' using errcode = '23514';
      end if;
    else
      v_cuil := nullif(regexp_replace(coalesce(ev->>'cuil', ''), '\D', '', 'g'), '');   -- Transportista Interno: CUIL opcional
      if v_cuil is not null and length(v_cuil) <> 11 then raise exception 'CUIL_INVALID: el CUIL debe tener 11 dígitos' using errcode = '23514'; end if;
    end if;
    -- RC4.1: email del receptor (segunda pantalla). Opcional; si viene, debe ser válido.
    v_email := nullif(lower(trim(coalesce(ev->>'email', ''))), '');
    if cristian and v_commercial and v_email is null then raise exception 'EMAIL_REQUIRED: el email del receptor es obligatorio' using errcode = '23514'; end if;
    if v_email is not null and not public.is_valid_email(v_email) then raise exception 'EMAIL_INVALID: el email no es válido' using errcode = '23514'; end if;
    v_dni := nullif(regexp_replace(coalesce(ev->>'dni', ''), '\D', '', 'g'), '');
    if v_dni is null and v_cuil is not null then v_dni := substr(v_cuil, 3, 8); end if;
    if v_dni is not null and length(v_dni) not between 7 and 8 then raise exception 'DNI_INVALID: el DNI debe tener 7 u 8 dígitos' using errcode = '23514'; end if;
  end if;
  -- cobranza (Cristian): el chofer no cambia el importe esperado
  if v_commercial and st.task in ('COBRANZA','AMBAS') then
    if col is null or coalesce(col->>'status', 'PENDIENTE') = 'PENDIENTE' then raise exception 'COLLECTION_REQUIRED: indicá el resultado de la cobranza' using errcode = '23514'; end if;
    if col->>'status' not in ('COBRADO','COBRO_PARCIAL','NO_COBRADO') then raise exception 'BAD_COLLECTION' using errcode = '22023'; end if;
    if col->>'status' in ('COBRO_PARCIAL','NO_COBRADO') and coalesce(trim(col->>'note'), '') = '' then raise exception 'COLLECTION_NOTE_REQUIRED: cobro parcial exige observación y no cobrado exige motivo' using errcode = '23514'; end if;
    if col->>'status' in ('COBRADO','COBRO_PARCIAL') and coalesce((col->>'amount')::numeric, 0) <= 0 then raise exception 'COLLECTION_AMOUNT_REQUIRED' using errcode = '23514'; end if;
  end if;
  loc := public._loc(p_extra->'location', st);
  update public.route_stops set outcome = p_outcome, outcome_at = now(), outcome_by = auth.uid(), outcome_note = nullif(trim(p_note),''), outcome_reason = nullif(trim(p_reason),''),
    finish_location = loc, location_warning = coalesce(case when loc->>'outside_m' is not null then 'FUERA DEL RADIO (' || (loc->>'outside_m') || ' m)' end, location_warning),
    collection_status = case when st.task in ('COBRANZA','AMBAS') then col->>'status' else collection_status end,
    collected_amount = case when st.task in ('COBRANZA','AMBAS') then nullif(col->>'amount','')::numeric else collected_amount end,
    payment_mode = case when st.task in ('COBRANZA','AMBAS') then col->>'mode' else payment_mode end,
    collection_note = case when st.task in ('COBRANZA','AMBAS') then nullif(trim(col->>'note'),'') else collection_note end
  where id = p_stop returning * into st;
  if p_outcome in ('ENTREGADO','ENTREGA_PARCIAL') then
    -- La entrega guarda el email USADO (inmutable aunque el perfil cambie después)
    if sig is not null then
      insert into public.stop_evidence(stop_id, receiver_name, signature_png, signature_sha256, receiver_cuil, created_by, receiver_email, receiver_dni, evidence_kind)
      values (p_stop, coalesce(nullif(trim(ev->>'receiver_name'), ''), 'Sin receptor (tarea)'), sig, encode(sha256(sig), 'hex'), v_cuil, auth.uid(), case when v_commercial then v_email end, v_dni,
              case when st.stop_type = 'UBICACION_INTERNA' then 'RECEPCION_INTERNA' when v_task then 'TAREA' else 'ENTREGA_CLIENTE' end)
      on conflict (stop_id) do nothing;
    end if;
    -- RECEPCIÓN INTERNA DE TRASLADO: queda trazado qué pedidos llegaron a qué sucursal, quién recibió, quién trasladó, cuándo y dónde
    if st.stop_type = 'UBICACION_INTERNA' then
      insert into public.audit_log(actor_id, action, target_type, target_id, after)
      values (auth.uid(), 'INTERNAL_TRANSFER_RECEIVED', 'route_stop', p_stop::text, jsonb_build_object(
        'route_id', st.route_id, 'route_number', r.number, 'internal_location_key', st.internal_location_key, 'location_name', st.client_name, 'address', st.address,
        'order_numbers', to_jsonb(st.order_numbers), 'outcome', p_outcome, 'receiver_name', trim(ev->>'receiver_name'), 'signature_sha256', encode(sha256(sig), 'hex'),
        'transported_by', auth.uid(), 'at', now(), 'gps', loc));
    end if;
    -- Perfil reutilizable (misma capa de identidad que el DNI): nombre, DNI y email para próximas entregas
    if v_commercial and v_cuil is not null then perform public._upsert_identity_profile(v_cuil, trim(ev->>'receiver_name'), v_dni, v_email, st.client_key); end if;
    -- Recibido Conforme: entrega TOTAL confirmada + email válido → comprobante único + envío automático (la falla del email nunca revierte la entrega)
    if v_commercial and p_outcome = 'ENTREGADO' and v_email is not null then perform public._create_delivery_receipt(st, r, trim(ev->>'receiver_name'), v_email); v_receipt := true; end if;
    if v_commercial and coalesce(trim(st.customer_email), '') <> '' and not v_receipt then
      insert into public.customer_email_jobs(route_id, stop_id, kind, recipient, idempotency_key)
      values (st.route_id, st.id, case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end, lower(trim(st.customer_email)), st.route_id || '|' || st.id || '|' || case when p_outcome = 'ENTREGADO' then 'DELIVERED' else 'PARTIAL' end)
      on conflict (idempotency_key) do nothing;
    end if;
  end if;
  if p_op_id is not null then insert into public.stop_outcome_ops(op_id, stop_id) values (p_op_id, p_stop); end if;
  perform public._queue_on_the_way(st.route_id);
  return st;
end; $function$

