import {describe,it,expect,vi} from 'vitest';
import {sendCommercialDecisionEmails} from '../../supabase/functions/_shared/commercial-decision-mail.js';
import {corporateMail} from '../../supabase/functions/_shared/corporate-mail.js';
vi.mock('../../supabase/functions/_shared/corporate-mail.js',()=>({corporateMail:vi.fn()}));
describe('Avisos de decisiones comerciales',()=>{
 for(const [scenario,expected] of [['guard-error','ERROR'],['config','ERROR'],['removed',null],['late-guard-error','ERROR'],['uncertain','HELD'],['accepted','SENT']]){
  it(scenario,async()=>{
   let checks=0; const states=[];
   const sb={rpc:async(name,args)=>{
    if(name.endsWith('_claim'))return {data:[{id:1,recipient:'qa@example.invalid',event_id:1,event_kind:'APROBADA'}]};
    if(name.endsWith('_guard')){
     checks++;
     if(scenario==='guard-error'||(scenario==='late-guard-error'&&checks===2))return {error:{message:'unavailable'}};
     return {data:scenario!=='removed'};
    }
    states.push(args.p_state);return {};
   }};
   const send=vi.fn(async message=>{
    if(scenario==='config')throw Object.assign(new Error('configuration changed'),{code:'ABORTED'});
    await message.beforeData();
    if(scenario==='uncertain')throw Object.assign(new Error('uncertain'),{phase:'AFTER_SEND'});
    return {id:'smtp:test'};
   });
   corporateMail.mockReturnValue({runtime:async()=>({provider:'SMTP',connected:true,available_slots:1}),send});
   await sendCommercialDecisionEmails(sb,{});
   expect(states).toEqual(expected?[expected]:[]);
   if(['removed','guard-error'].includes(scenario))expect(send).not.toHaveBeenCalled();
  });
 }
});
