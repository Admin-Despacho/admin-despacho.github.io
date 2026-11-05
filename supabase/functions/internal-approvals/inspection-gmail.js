import { buildMime, base64url, validEmail } from '../_shared/comms-core.js';

// Gmail no admite claves de idempotencia. La reserva CAS persiste antes del HTTP;
// si hay aceptación incierta o progreso parcial, nunca se libera automáticamente.
export const GMAIL_HOLD = 'GMAIL_INSPECTION_HOLD:';
export function inspectionGmailSender({ provider, gmailStore, claim, finish, authorized, audit }) {
  return async j => {
    if (String(j.error || '').startsWith(GMAIL_HOLD)) return { id:j.id, status:'ERROR', held:true };
    const lock = GMAIL_HOLD + crypto.randomUUID();
    if (!await claim(j, lock)) return { id:j.id, status:'ERROR', skipped:true };
    let accepted = 0, posting = false;
    try {
      const status = await gmailStore.gmailStatus();
      if (!status.connected || status.needs_reconnect || !validEmail(status.email)) throw new Error('Gmail requiere reconexión');
      const recipients = [...new Set(j.recipients.map(x => String(x).trim().toLowerCase()))];
      if (!recipients.length || recipients.some(x => !validEmail(x))) throw new Error('Destinatarios guardados inválidos');
      const esc = s => String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
      for (const to of recipients) {
        const token = await provider.prepare(false);
        const rate = await gmailStore.acquireRate(100, 6000, 200);
        if (rate.wait_ms > 0) throw new Error('Cupo Gmail ocupado; reintentar más tarde');
        if (!await authorized(j)) throw new Error('Superior inactivo o inspección no aprobada');
        const raw = base64url(buildMime({from:status.email,fromName:'OK Despacho',to,subject:j.subject,
          html:'<pre>' + esc(j.body) + '</pre>',attachments:[]}));
        posting = true;
        const response = await provider.post(raw, token);
        const sent = provider.interpret(response);
        accepted++;
        posting = false;
        await audit(j,'INSPECTION_GMAIL_SENT',{recipient:to,gmail_id:sent.id,inspection_id:j.inspection_id});
      }
      await finish(j,lock,{status:'ENVIADO',sent_at:new Date().toISOString(),error:null});
      return {id:j.id,status:'ENVIADO'};
    } catch (e) {
      const held = accepted > 0 || e.phase === 'AFTER_SEND' || (posting && (!e.status || e.status >= 500));
      const error = String(e.message || e).slice(0,400);
      if (held) {
        // No liberar la reserva: también cubre caída después del envío y fallo de auditoría/DB.
        await audit(j,'INSPECTION_GMAIL_HELD',{error,accepted}).catch(()=>{});
        return {id:j.id,status:'ERROR',held:true,error:'Por verificar: '+error};
      }
      await finish(j,lock,{status:'ERROR',error,retry_count:(j.retry_count||0)+1});
      await audit(j,'INSPECTION_GMAIL_ERROR',{error}).catch(()=>{});
      return {id:j.id,status:'ERROR',error};
    }
  };
}
