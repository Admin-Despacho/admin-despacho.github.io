// Destino al tocar una notificación push. Las rutas existentes NO cambian. Autorizaciones comerciales (auditoría B-AL-02): los avisos de la
// ALARMA URGENTE abren ESA alarma (#/autorizaciones?alarma_n=<id del aviso>); la app la busca con com_alarm_by_notification (solo para su destinatario).
export const urlFor = (n: any, appUrl: string) => {
  const rid = n.route_id ? encodeURIComponent(n.route_id) : '';
  if (String(n.type || '').startsWith('COM_ALARMA')) return appUrl + '/#/autorizaciones?alarma_n=' + encodeURIComponent(String(n.id || ''));
  if (n.type === 'REQUEST_CREATED') return appUrl + '/#/solicitudes' + (rid ? '?route=' + rid : '');
  if (String(n.type || '').startsWith('REQUEST_')) return appUrl + '/#/solicitudes' + (rid ? '?route=' + rid : '');
  return appUrl + '/#/mis-hojas' + (rid ? '?route=' + rid : '');
};
