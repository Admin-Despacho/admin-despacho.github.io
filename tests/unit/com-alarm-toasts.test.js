import {describe,it,expect,vi} from 'vitest';
import {createAlarmToasts,TOAST_MS} from '../../src/online/com-alarm-toasts.js';
// Temporizadores falsos: el avance del reloj es explícito.
function rig(start=1e12){let t=start;const timers=new Map();let seq=0;const later=(fn,ms)=>{const id=++seq;timers.set(id,{at:t+ms,fn});return id;};const clear=id=>timers.delete(id);
 const advance=ms=>{t+=ms;for(const [id,x] of [...timers]){if(x.at<=t){timers.delete(id);x.fn();}}};const onChange=vi.fn();
 const T=createAlarmToasts({later,clear,now:()=>t,onChange});return {T,advance,timers,onChange,now:()=>t};}
const A=(id,status='PENDIENTE_ATENCION',raised=1e12-3600e3)=>({id,number:'ALR-'+id,status,raised_at:new Date(raised).toISOString()});
describe('Avisos de transición de alarmas',()=>{
 it('la primera consulta es línea de base: lo histórico (ATENDIDO) nunca se muestra',()=>{const {T}=rig();T.observe([A('1','ATENDIDA'),A('2','ATENDIDA'),A('3')]);expect(T.list()).toEqual([]);});
 it('pendiente → atendida: una confirmación que vence a los 5 s exactos',()=>{const {T,advance}=rig();T.observe([A('3')]);T.observe([A('3','ATENDIDA')]);expect(T.list().map(x=>x.id)).toEqual(['3']);advance(TOAST_MS-1);expect(T.list().length).toBe(1);advance(1);expect(T.list()).toEqual([]);});
 it('consultas repetidas no reinician el temporizador ni duplican',()=>{const {T,advance,timers}=rig();T.observe([A('3')]);T.observe([A('3','ATENDIDA')]);advance(3000);T.observe([A('3','ATENDIDA')]);T.observe([A('3','ATENDIDA')]);expect(timers.size).toBe(1);advance(2000);expect(T.list()).toEqual([]);});
 it('cerrada (X o vencida) no vuelve',()=>{const {T,advance}=rig();T.observe([A('3'),A('4')]);T.observe([A('3','ATENDIDA'),A('4','CANCELADA')]);expect(T.close('3')).toBe(true);T.observe([A('3','ATENDIDA'),A('4','CANCELADA')]);expect(T.list().map(x=>x.id)).toEqual(['4']);advance(5000);T.observe([A('3','ATENDIDA'),A('4','CANCELADA')]);expect(T.list()).toEqual([]);expect(T.isClosed('4')).toBe(true);});
 it('varias alarmas: temporizadores independientes',()=>{const {T,advance}=rig();T.observe([A('1'),A('2')]);T.observe([A('1','ATENDIDA'),A('2')]);advance(3000);T.observe([A('1','ATENDIDA'),A('2','ATENDIDA')]);expect(T.list().length).toBe(2);advance(2000);expect(T.list().map(x=>x.id)).toEqual(['2']);advance(3000);expect(T.list()).toEqual([]);});
 it('pendiente que desaparece de una lista COMPLETA → «ya no pendiente»; con lista truncada no se infiere',()=>{const r=rig();r.T.observe([A('5')]);r.T.observe([],{complete:false});expect(r.T.list()).toEqual([]);r.T.observe([]);expect(r.T.list()[0].status).toBe('NO_PENDIENTE');});
 it('alarma creada y resuelta entre dos consultas de esta sesión → confirmación; una vieja no',()=>{const r=rig();r.T.observe([]);r.T.observe([A('9','ATENDIDA',r.now()-1000),A('8','ATENDIDA',r.now()-3*3600e3)]);expect(r.T.list().map(x=>x.id)).toEqual(['9']);});
 it('dispose cancela todos los temporizadores',()=>{const {T,timers}=rig();T.observe([A('1')]);T.observe([A('1','ATENDIDA')]);expect(timers.size).toBe(1);T.dispose();expect(timers.size).toBe(0);expect(T.list()).toEqual([]);});
 it('una pendiente nunca genera confirmación',()=>{const {T}=rig();T.observe([A('1')]);T.observe([A('1')]);T.observe([A('1')]);expect(T.list()).toEqual([]);});
});
