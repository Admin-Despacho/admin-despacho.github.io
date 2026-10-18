// Comprueba los XLSX sintéticos con el MISMO parser de public/legacy/worker.js.
// No importa datos reales ni conecta con Supabase.
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
const base = process.argv[2] || 'tests/e2e/out/synthetic';
const ctx = vm.createContext({ console, Uint8Array, ArrayBuffer, Date, TextDecoder, TextEncoder, setTimeout, clearTimeout });
vm.runInContext(fs.readFileSync('public/legacy/xlsx.full.min.js','utf8'), ctx);
vm.runInContext(fs.readFileSync('public/legacy/worker.js','utf8'), ctx);
const cases = [
  ['informe_pedidos__31_.xlsx','pedidos',9],
  ['SALDO_COMPROBANTE__3_.xlsx','sc',8],
  ['SALDO_CUENTA_CORRIENTE.xlsx','cc',8]
];
for(const [name, kind, minimum] of cases){
 const data = fs.readFileSync(path.join(base,name));
 const array = Uint8Array.from(data);
 const result = ctx.ExcelImporterCore.parse(array.buffer.slice(array.byteOffset,array.byteOffset+array.byteLength),name);
 if(!result.ok || result.kind!==kind || result.count<minimum)
   throw Error(name+': '+JSON.stringify({ok:result.ok,kind:result.kind,count:result.count,error:result.error}));
 console.log('PASS',kind,'records',result.count,'warnings',result.warnings.join(' | '));
}
console.log('TOTAL 3 PASS / 0 FAIL');
