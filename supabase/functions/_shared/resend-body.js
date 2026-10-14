// Cuerpo del POST https://api.resend.com/emails para la Edge Function internal-approvals.
// Mismos campos de siempre (from, to, subject, html, text). Si el mail trae adjuntos (por ejemplo el logo inline del Recibido Conforme),
// se envían en base64 con content_type y, para imágenes inline, content_id (debe coincidir con src="cid:…" del HTML).
export function resendBody(m, from) {
  const body = { from, to: [m.to], subject: m.subject, html: m.html, text: m.text };
  if (Array.isArray(m.attachments) && m.attachments.length)
    body.attachments = m.attachments.map(a => Object.assign({ filename: a.filename, content: a.content }, a.content_type ? { content_type: a.content_type } : {}, a.content_id ? { content_id: a.content_id } : {}));
  return body;
}
// Logo oficial listo para inline (los bytes vienen del módulo generado desde el PNG congelado)
export function inlineLogoFrom(mod) { return { filename: mod.LOGO_FILENAME, content: mod.LOGO_PNG_BASE64, content_type: mod.LOGO_CONTENT_TYPE, content_id: mod.LOGO_CID }; }