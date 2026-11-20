import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { PDFDocument, StandardFonts } from 'npm:pdf-lib@1.17.1';

Deno.serve(async req => {
  const secret = Deno.env.get('COMM_CRON_SECRET');
  if (!secret || req.headers.get('x-comm-cron') !== secret) return new Response('Forbidden', {status:403});
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {auth:{persistSession:false}});
  const bucket = sb.storage.from('route-pdfs');
  try {
    const {data:batch} = await sb.from('daily_dispatch_batches').select('id').eq('state','WAIT_PDF').order('report_day').limit(1).maybeSingle().throwOnError();
    if (!batch) return Response.json({created:0});
    const {data:rows} = await sb.from('daily_dispatch_batch_routes').select('route_id,route_version,route_number').eq('batch_id',batch.id).gt('route_version',1).throwOnError();
    let created = 0;
    for (const row of rows || []) {
      const id = row.route_id, version = row.route_version;
      const {data:files} = await sb.from('route_pdfs').select('storage_path,route_version').eq('route_id',id).eq('status','OK').lte('route_version',version).order('route_version',{ascending:false}).limit(1).maybeSingle().throwOnError();
      if (!files || files.route_version === version) continue;
      const {data:changes} = await sb.from('route_change_events').select('route_version,event_type,after,at').eq('route_id',id).gt('route_version',files.route_version).lte('route_version',version).order('route_version').throwOnError();
      if (!changes || changes.length !== version-files.route_version || changes.some((c,i)=>c.route_version!==files.route_version+i+1 || c.event_type!=='INTERNAL_STOP_ADDED' || !c.after?.client_name)) continue;
      const {data:approved} = await sb.from('audit_log').select('at').eq('target_id',id).eq('action','INTERNAL_ROUTE_APPROVED').gte('at',changes.at(-1).at).limit(1).maybeSingle().throwOnError();
      if (!approved) continue;
      const {data:source,error} = await bucket.download(files.storage_path);
      if (error || !source) throw Error('PDF_ORIGINAL');
      const doc = await PDFDocument.load(await source.arrayBuffer(),{updateMetadata:false});
      const font = await doc.embedFont(StandardFonts.Helvetica);
      for (const change of changes) {
        let page = doc.addPage([595,842]), y=782;
        const line=(text:string,size=12)=>{
          let current='';
          for(const word of String(text).replace(/[\r\n\t]+/g,' ').split(/ +/)){
            if(current && font.widthOfTextAtSize(current+' '+word,size)>490){draw(current);current='';}
            current += (current?' ':'')+word;
          }
          if(current) draw(current);
          function draw(value:string){if(y<62){page=doc.addPage([595,842]);y=782;}page.drawText(value,{x:45,y,size,font});y-=size+9;}
        };
        line('OK Accesorios · Hoja de ruta '+row.route_number,18);
        line('Versión '+change.route_version+' · Parada agregada',15);
        y-=14;
        for(const [label,key] of [['Parada','client_name'],['Tipo','stop_type'],['Acción','action'],['Domicilio','address'],['Contacto','contact_name'],['Teléfono','contact_phone'],['Indicaciones','instructions']]){
          if(change.after[key]) line(label+': '+change.after[key]);
        }
      }
      const bytes=await doc.save(), name='Hoja_'+row.route_number+'_v'+version+'.pdf', path=id+'/v'+version+'/'+name;
      const {error:upload}=await bucket.upload(path,bytes,{contentType:'application/pdf',upsert:false});
      if(upload){
        const {data:stored}=await bucket.download(path);
        if(!stored) throw Error('PDF_UPLOAD');
        const existing=new Uint8Array(await stored.arrayBuffer());
        if(existing.length!==bytes.length||!bytes.every((b,i)=>b===existing[i]))throw Error('PDF_CONFLICT');
      }
      const {error:registration}=await sb.from('route_pdfs').upsert({route_id:id,route_version:version,route_number:row.route_number,file_name:name,storage_path:path,status:'OK',error:null,generated_at:new Date().toISOString()},{onConflict:'route_id,route_version'});
      if(registration)throw Error('PDF_REGISTER');
      created++;
    }
    return Response.json({created});
  } catch(e){return Response.json({error:String(e.message).slice(0,120)},{status:500});}
});
