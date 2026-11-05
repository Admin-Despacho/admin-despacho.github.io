// SOLO LECTURA · pegar en la consola del navegador con la app de PRODUCCIÓN abierta y la sesión iniciada (no escribe nada).
// Ejecutar primero como ADMINISTRADOR GENERAL y después como SUPERIOR DESPACHO, y enviar el resultado a Dirección Técnica.
(async () => {
  const A = window.OKD_ONLINE && window.OKD_ONLINE.api; if (!A || !A.routesListInfo) return console.log('La versión abierta no tiene routesListInfo (parche no aplicado).');
  const me = await A.me(), s = await A.searchRoutes({}), rows = (s.rows || s || []).filter(r => r.carrier_id === 'INTERNO').slice(0, 30);
  let info = [], error = null; try { info = await A.routesListInfo(rows.map(r => r.id)); } catch (e) { error = e.message; }
  const by = Object.fromEntries(info.map(x => [x.id, x]));
  console.table(rows.map(r => ({ hoja: r.number, estado: r.operational_status, fecha_programada: (by[r.id] || {}).sheet_date || '(sin dato)', salida: (by[r.id] || {}).started_at || '(sin dato)',
    regreso: (by[r.id] || {}).depot_arrived_at || '(sin dato)', patente: (by[r.id] || {}).plate || '(sin dato)', devuelta_por_routesListInfo: !!by[r.id] })));
  const extra = info.filter(x => !rows.some(r => r.id === x.id)).length;
  console.log({ usuario: me.email, rol: me.role, hojas_listadas: rows.length, datos_devueltos: info.length, devueltas_fuera_del_listado: extra, error });
})();
