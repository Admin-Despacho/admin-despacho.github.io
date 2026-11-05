-- RECUPERACIÓN V4.25 · SOLO si se decide retirar el módulo ANTES de usarlo en producción. ATENCIÓN: borra las inspecciones cargadas.
-- Si ya hay inspecciones reales, NO ejecutar: alcanza con volver la pantalla a V4.24.1 (las tablas quedan inertes y se conservan).
BEGIN;
alter table public.notifications drop column if exists inspection_id;
drop table if exists public.vehicle_inspection_email_requests, public.vehicle_inspection_events, public.vehicle_inspection_items, public.vehicle_inspections, public.vehicle_inspection_controls cascade;
drop sequence if exists public.vehicle_inspection_number_seq;
drop function if exists public.inspection_save_draft(jsonb), public.inspection_submit(uuid), public.inspection_review(uuid,text,text), public.inspection_new_revision(uuid,uuid),
  public.inspection_email_request(uuid,text[],text,text), public._insp_me(), public._insp_event(uuid,text,jsonb), public._insp_can_view(public.vehicle_inspections), public.trg_insp_items_locked();
COMMIT;
