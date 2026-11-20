// Informe diario: usa el snapshot publicado del PDF, nunca el saldo mutable de la entrega.
const labels={INTERNO:'Transporte interno',EXTERNO:'Transporte externo',TERCERIZADO:'Transporte tercerizado'};
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=new Intl.NumberFormat('es-AR');
const currency=new Intl.NumberFormat('es-AR',{style:'currency',currency:'ARS',minimumFractionDigits:2});
const money=c=>currency.format(c/100);
function cents(v){if(v==null||v===''||!Number.isFinite(Number(v))||Number(v)<0)throw Error('MONTO_INVALIDO');const n=Math.round(Number(v)*100);if(!Number.isSafeInteger(n))throw Error('MONTO_INVALIDO');return n;}
function packages(v){if(v==null||v==='')return null;const n=Number(v);if(!Number.isSafeInteger(n)||n<0)throw Error('BULTOS_INVALIDOS');return n;}
const blank=()=>({orders:0,transfers:0,transferStops:0,unnumberedTransfers:0,tasks:0,packages:0,missingPackages:0,amount:0});
function add(a,b){for(const k of Object.keys(a)){a[k]+=b[k];if(!Number.isSafeInteger(a[k]))throw Error('TOTAL_INVALIDO');}return a;}
export function summarizeRoute(route){
 const model=route.sheet_snapshot?.pdf_model;
 const stops=route.sheet_snapshot?.stops;
 if(!Array.isArray(model?.items)||!Array.isArray(stops))throw Error('SNAPSHOT_INCOMPLETO');
 const a=blank(), seen=new Set(), matched=new Set();
 const rows=model.items.filter(x=>x.type==='row');
 for(const item of rows){
  const r=item.r;
  if(!r||r.id==null||String(r.id)==='')throw Error('FILA_INVALIDA');
  const id=String(r.id);
  if(seen.has(id))continue;
  seen.add(id);
  const type=r.stopType||'PEDIDO';
  const sid=type==='UBICACION_INTERNA'?String(r.internalLocationKey??''):type==='PEDIDO'?String(r.mainOrder??''):'';
  if(type!=='TAREA'){
   if(!sid)throw Error('MOVIMIENTO_SIN_IDENTIFICADOR');
   const i=stops.findIndex((s,i)=>!matched.has(i)&&s.stop_type===type&&(type==='PEDIDO'?Array.isArray(s.order_numbers)&&s.order_numbers.map(String).includes(sid):String(s.internal_location_key??'')===sid));
   if(i<0)throw Error('MOVIMIENTO_NO_CONCILIADO');
   matched.add(i);
  }
  const b=packages(r.bultos);if(b===null)a.missingPackages++;else a.packages+=b;
  if(type==='UBICACION_INTERNA'){
   if(r.locationOrders!=null&&!Array.isArray(r.locationOrders))throw Error('TRASLADOS_INVALIDOS');
   const ids=new Set((r.locationOrders||[]).map(o=>String(o?.main??'').trim()).filter(Boolean));
   a.transferStops++;a.transfers+=ids.size+Number(!ids.size);a.unnumberedTransfers+=Number(!ids.size);
   // Un traslado jamás es una cobranza, aunque el modelo tenga un monto por error.
  }else if(type==='PEDIDO'){a.orders++;a.amount+=cents(r.monto);}
  else if(type==='TAREA'){a.tasks++;}
  else throw Error('TIPO_MOVIMIENTO_DESCONOCIDO');
 }
 if(stops.some((s,i)=>s.stop_type!=='TAREA'&&!matched.has(i)))throw Error('PARADA_NO_CONCILIADA');
 const kind=route.dispatch_mode==='EXTERNAL'?'TERCERIZADO':route.carrier_kind;
 if(!Object.hasOwn(labels,kind))throw Error('TRANSPORTE_DESCONOCIDO');
 const number=String(route.number??'');if(!number||!Number.isInteger(route.version)||!route.file_name)throw Error('HOJA_INVALIDA');
 return {...a,number,version:route.version,carrier:String(route.carrier_name??'—'),kind,status:String(route.operational_status??'—'),fileName:String(route.file_name)};
}
export function summarizeDay(routes){
 if(!Array.isArray(routes))throw Error('HOJAS_INVALIDAS');
 const total=blank(), groups=Object.fromEntries(Object.keys(labels).map(k=>[k,blank()])),seen=new Set();
 const rows=routes.map(summarizeRoute).sort((a,b)=>a.number.localeCompare(b.number));
 for(const r of rows){if(seen.has(r.number))throw Error('HOJA_DUPLICADA');seen.add(r.number);add(total,r);add(groups[r.kind],r);}
 return {rows,total,groups};
}
export function renderDailyDispatch({day,time,report}){
 const {rows,total:t,groups}=report;const date=day.split('-').reverse().join('/');
 const attached=rows.filter(r=>r.fileName!=='PDF pendiente');
 const pending=rows.filter(r=>r.fileName==='PDF pendiente');
 const intro=!rows.length?'Al cierre no hubo hojas nuevas para informar.':pending.length?'El resumen incluye todas las hojas. PDF pendientes al cierre: '+pending.map(r=>r.number+' v'+r.version).join(', ')+'.':'Adjuntamos las hojas de ruta de la jornada y el resumen de las operaciones de Despacho.';
 const mov=t.orders+t.transfers;
 const td='padding:9px 6px;border-bottom:1px solid #dce5e9;text-align:left;vertical-align:top;word-wrap:break-word;';
 const cells=(xs)=>'<tr>'+xs.map(x=>'<td style="'+td+'">'+esc(x)+'</td>').join('')+'</tr>';
 const header=(xs)=>'<tr>'+xs.map(x=>'<th scope="col" style="'+td+'background:#e6f5f8;color:#09232e">'+esc(x)+'</th>').join('')+'</tr>';
 const tile=(label,value)=>'<td width="50%" style="padding:5px;vertical-align:top"><div style="border:1px solid #dce5e9;padding:12px"><div style="color:#536976;font-size:12px">'+esc(label)+'</div><strong style="font-size:23px;color:#008da5">'+esc(value)+'</strong></div></td>';
 const bars=Object.entries(groups).map(([k,g])=>{const n=g.orders+g.transfers,p=mov?Math.round(n/mov*100):0;return '<p style="margin:10px 0 4px">'+esc(labels[k])+' · '+fmt.format(n)+' movimientos</p><table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td width="'+p+'%" bgcolor="'+({INTERNO:'#089db4',EXTERNO:'#2563eb',TERCERIZADO:'#ec942b'}[k])+'" height="8"></td><td bgcolor="#e6edf0" height="8"></td></tr></table>';}).join('');
 const statusLabel=s=>({COMPLETADA:'Completada',EN_CURSO:'En curso',PUBLICADA:'Publicada',PENDIENTE:'Pendiente'}[s]||s);
 const amount=r=>r.orders?money(r.amount):'No corresponde';
 const pack=r=>fmt.format(r.packages)+(r.missingPackages?' (faltan '+fmt.format(r.missingPackages)+')':'');
 const subject='OK DESPACHO | Informe diario de despacho – '+date;
 const html='<div style="font-family:Arial,sans-serif;color:#102b36;background:#f2f6f7;padding:10px"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:760px;margin:auto;background:#fff"><tr><td bgcolor="#09232e" style="padding:22px;color:white"><strong style="color:#16dcef;font-size:26px">OK DESPACHO</strong><h2 style="margin:8px 0">Informe diario de operaciones</h2>'+esc(date+' · '+time+' hs')+'</td></tr><tr><td style="padding:15px"><p>Equipo:</p><p>'+esc(intro)+'</p><table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr>'+tile('Hojas de ruta',rows.length)+tile('Pedidos comerciales',t.orders)+'</tr><tr>'+tile('Traslados entre sucursales',t.transfers)+tile('Bultos informados',pack(t))+'</tr></table><div style="border:1px solid #dce5e9;padding:12px;margin:8px 0"><div>Total a cobrar por pedidos comerciales</div><strong style="color:#009d61;font-size:26px">'+esc(money(t.amount))+'</strong><p style="font-size:12px;margin:5px 0">Importe de las hojas publicadas; no es dinero efectivamente cobrado. No incluye traslados.</p></div><h3>Resumen de movimientos</h3><table width="100%" cellspacing="0" cellpadding="0" style="font-size:13px">'+header(['Concepto','Cantidad','A cobrar'])+cells(['Pedidos comerciales',fmt.format(t.orders),money(t.amount)])+cells(['Traslados entre sucursales',fmt.format(t.transfers),'No corresponde'])+cells(['Total movimientos',fmt.format(mov),money(t.amount)])+'</table><p style="font-size:12px">Traslados: pedidos principales identificados más una visita por traslado sin número. '+fmt.format(t.unnumberedTransfers)+' visita(s) sin número; '+fmt.format(t.tasks)+' tarea(s) adicionales excluidas de pedidos y traslados. Los bultos no informados no se computan como cero.</p><h3>Detalle por hoja de ruta</h3><table width="100%" cellspacing="0" cellpadding="0" style="font-size:12px;table-layout:fixed">'+header(['Hoja / transportista','Pedidos / traslados','Bultos','A cobrar / estado'])+rows.map(r=>'<tr><td style="'+td+'"><b>'+esc(r.number+' v'+r.version)+'</b><br>'+esc(r.carrier)+'</td><td style="'+td+'">'+esc(r.orders+' / '+r.transfers)+'</td><td style="'+td+'">'+esc(pack(r))+'</td><td style="'+td+'">'+esc(amount(r))+'<br>'+esc(statusLabel(r.status))+'</td></tr>').join('')+cells(['TOTAL',t.orders+' / '+t.transfers,pack(t),money(t.amount)])+'</table><h3>Distribución por tipo de transporte</h3>'+bars+'<h3>Archivos adjuntos · '+attached.length+' PDF</h3><ul>'+attached.map(r=>'<li>'+esc(r.fileName)+'</li>').join('')+'</ul></td></tr><tr><td bgcolor="#09232e" style="padding:18px;color:#fff"><b>OK ACCESORIOS | Departamento de Despacho</b><p style="font-size:12px;color:#c7dce4">Informe generado automáticamente por OK DESPACHO ONLINE.</p></td></tr></table></div>';
 const text=[subject,intro,'Hojas: '+rows.length,'Pedidos comerciales: '+t.orders,'Traslados: '+t.transfers+' (sin cobranza)','Bultos informados: '+pack(t),'Total a cobrar: '+money(t.amount)+' (no cobrado)',...rows.map(r=>[r.number+' v'+r.version,r.carrier,r.orders+' pedidos',r.transfers+' traslados',pack(r)+' bultos',amount(r),statusLabel(r.status),r.fileName].join(' | '))].join('\n');
 return {subject,html,text};
}
