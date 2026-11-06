"""Targeted hierarchy UI regression; synthetic profiles, no Supabase writes or emails."""
import asyncio
import os
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from playwright.async_api import async_playwright


async def main():
    root = Path(__file__).resolve().parents[2]
    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=str(root)))
    Thread(target=server.serve_forever, daemon=True).start()
    async with async_playwright() as p:
        browser = await p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH'))
        page = await browser.new_page()
        await page.goto(f'http://127.0.0.1:{server.server_port}/tests/')
        await page.evaluate("""async () => {
          document.body.innerHTML = '<div id="usersPanel"><div id="upWrap"></div></div>';
          const { UsersPanel } = await import('/src/online/users-ui.js');
          const admin = {id:'admin',full_name:'Admin QA',email:'admin@example.invalid',role:'ADMIN',status:'ACTIVO'};
          // Same shape as the real list endpoint: no permission_overrides field.
          const users = [admin,
            {id:'driver',full_name:'Internal QA',email:'driver@example.invalid',role:'TRANSPORTISTA_INTERNO',status:'ACTIVO',supervisor_user_id:null,carriers:[]},
            {id:'supervisor',full_name:'Superior QA',role:'SUPERVISOR_DESPACHO',status:'ACTIVO'},
            {id:'disabled',full_name:'Inactive QA',role:'SUPERVISOR_DESPACHO',status:'DESHABILITADO'},
            {id:'operator',full_name:'Operator QA',role:'OPERARIO_DEPOSITO',status:'ACTIVO'}];
          const calls = [];
          const api = {
            getSession: async()=>({}), listUsers:async()=>structuredClone(users),listCarriers:async()=>[],
            action:async(action,payload)=>{calls.push({action,payload}); if ('supervisor_user_id' in payload) throw Error('Legacy edit path used'); return users[1];},
            setUserSupervisor:async(id,sup)=>{calls.push({rpc:true,id,sup});users.find(u=>u.id===id).supervisor_user_id=sup;}
          };
          window.qa = {users,calls, panel:new UsersPanel(api,admin)};
          qa.panel.users=structuredClone(users);qa.panel.openEdit(qa.panel.users[1]);
        }""")
        assert await page.locator('#nuSup option[value="supervisor"]').count() == 1
        assert await page.locator('#nuSup option[value="disabled"]').count() == 0
        assert await page.locator('#nuSup option[value="operator"]').count() == 0
        await page.select_option('#nuSup', 'supervisor')
        await page.click('#umSave')
        await page.wait_for_function('qa.calls.some(c=>c.rpc) && !document.querySelector("#editModal")')
        result = await page.evaluate('({user:qa.users[1],calls:qa.calls})')
        assert result['user']['role'] == 'TRANSPORTISTA_INTERNO'
        assert result['user']['supervisor_user_id'] == 'supervisor'
        assert result['calls'][-1] == {'rpc': True, 'id': 'driver', 'sup': 'supervisor'}
        await page.click('[data-pick="driver"]')   # V4.26 (diseño V3): se elige al usuario en su tarjeta y el editor se abre en el panel
        assert await page.input_value('#nuSup') == 'supervisor'
        await page.click('#umCancel')
        # A new panel reads persisted state; it does not depend on the previous instance.
        await page.evaluate('async()=>{await qa.panel.reload();qa.panel.openEdit(qa.panel.users.find(u=>u.id==="driver"));}')
        assert await page.input_value('#nuSup') == 'supervisor'
        await page.click('#umSave')
        await page.wait_for_function('!document.querySelector("#editModal")')
        assert await page.evaluate('qa.calls.filter(c=>c.rpc).length') == 1
        print('PASS: active Superior without serialized overrides; inactive/operator excluded; RPC save/read; role unchanged; unchanged save idempotent')
        await browser.close()


if __name__ == '__main__':
    asyncio.run(main())
