// V4.25 · INSPECCIONES DE VEHÍCULOS · modo online (Supabase). Toda la validación y el alcance por equipo están en el servidor (funciones + RLS).
const fail = error => { if (error) throw Object.assign(new Error(error.message), { code: (String(error.message).match(/^[A-Z_]+/) || [])[0] }); };
export const SupabaseInsp = {
  async inspSaveDraft(p) { const { data, error } = await this.sb.rpc('inspection_save_draft', { p }); fail(error); return data; },
  async inspSubmit(id) { const { data, error } = await this.sb.rpc('inspection_submit', { p_id: id }); fail(error); return data; },
  async inspReview(id, decision, reason) { const { data, error } = await this.sb.rpc('inspection_review', { p_id: id, p_decision: decision, p_reason: reason || null }); fail(error); return data; },
  async inspNewRevision(id, clientId) { const { data, error } = await this.sb.rpc('inspection_new_revision', { p_id: id, p_client_id: clientId }); fail(error); return data; },
  async inspEmailRequest(id, to, subject, body) {   // 1) se registra el pedido confirmado; 2) se envía con la infraestructura existente (internal-approvals)
    const { data: rid, error } = await this.sb.rpc('inspection_email_request', { p_id: id, p_recipients: to, p_subject: subject, p_body: body }); fail(error);
    const { data, error: e2 } = await this.sb.functions.invoke('internal-approvals', { body: { action: 'send_inspection_emails', request_ids: [rid] } });
    if (e2) return { id: rid, status: 'ERROR', error: e2.message };
    const r = ((data && data.results) || []).find(x => x.id === rid) || {}; return { id: rid, status: r.status || 'PENDIENTE_ENVIO', error: r.error || null };
  },
  async inspVehicles() { const { data, error } = await this.sb.from('vehicles').select('id,name,plate,type,brand,model,current_km,active').eq('active', true).order('name'); fail(error); return data || []; },
  async inspList(f = {}) {
    let q = this.sb.from('vehicle_inspections').select('*').order('created_at', { ascending: false }).limit(f.limit || 500);
    if (f.from) q = q.gte('created_at', f.from); if (f.to) q = q.lte('created_at', f.to + 'T23:59:59');
    if (f.status) q = q.eq('status', f.status); if (f.vehicle_id) q = q.eq('vehicle_id', f.vehicle_id);
    if (f.plate) q = q.ilike('plate', '%' + f.plate.replace(/[^0-9A-Za-z ]/g, '') + '%'); if (f.responsable) q = q.ilike('created_by_name', '%' + f.responsable.replace(/[%_]/g, '') + '%');
    const { data, error } = await q; fail(error); return data || [];
  },
  async inspDetail(id) {
    const [a, b, c] = await Promise.all([this.sb.from('vehicle_inspections').select('*').eq('id', id).maybeSingle(),
      this.sb.from('vehicle_inspection_items').select('*').eq('inspection_id', id).order('item_no'), this.sb.from('vehicle_inspection_events').select('*').eq('inspection_id', id).order('at')]);
    fail(a.error); fail(b.error); fail(c.error); if (!a.data) throw Object.assign(new Error('No existe o no tenés acceso.'), { code: 'NOT_FOUND' });
    return { inspection: a.data, items: b.data || [], events: c.data || [] };
  },
  async inspEvents(ids) { if (!ids.length) return []; const { data, error } = await this.sb.from('vehicle_inspection_events').select('*').in('inspection_id', ids).order('at'); fail(error); return data || []; },
  async inspItems(ids) { if (!ids.length) return []; const { data, error } = await this.sb.from('vehicle_inspection_items').select('*').in('inspection_id', ids).order('item_no'); fail(error); return data || []; },
};
