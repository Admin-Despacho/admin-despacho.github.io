// Genera PDFs reales del informe (pdf-lib) para revisar su contenido con pdftotext.
import { reportPdf } from '../../supabase/functions/_shared/report-pdf.js';
import { buildReport, atLocal } from '../../supabase/functions/_shared/report-engine.js';
import { demoRoutes, DEMO_COSTS } from '../../supabase/functions/_shared/report-demo-data.js';
const out = Deno.args[0];
const routes = demoRoutes();
const w = buildReport({ routes, costs: DEMO_COSTS, sel: { kind: 'WEEKLY', saturday: '2026-10-10' }, now: atLocal('2026-10-10', '15:00'), type: 'WEEKLY' });
const m = buildReport({ routes, costs: DEMO_COSTS, sel: { kind: 'MONTHLY', year: 2026, month: 9 }, now: atLocal('2026-09-30', '23:30'), type: 'MONTHLY' });
await Deno.writeFile(out + '/Informe_Cristian_Torres_Semanal_2026-10-10.pdf', await reportPdf(w));
await Deno.writeFile(out + '/Informe_Cristian_Torres_Mensual_2026-09.pdf', await reportPdf(m));
await Deno.writeTextFile(out + '/snapshots.json', JSON.stringify({ w, m }));
