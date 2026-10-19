import { chromium } from 'playwright';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
const root=resolve('dist');
const server=createServer(async(req,res)=>{try{const path=resolve(root,'.'+new URL(req.url,'http://localhost').pathname.replace(/\/$/,'/index.html'));if(!path.startsWith(root+'/'))throw Error('path');const data=await readFile(path);res.setHeader('Content-Type',({'.js':'text/javascript','.css':'text/css','.html':'text/html','.webp':'image/webp','.json':'application/json'})[extname(path)]||'application/octet-stream');res.end(data)}catch{res.statusCode=404;res.end()}});
await new Promise(r=>server.listen(4173,'127.0.0.1',r));
let browser;
try{
 browser=await chromium.launch({headless:true});
 for(const [name,width,height,mobile] of [['notebook',1366,768,false],['android',393,851,true],['android-small',360,800,true],['notebook-small',800,700,false]]){
  const page=await browser.newPage({viewport:{width,height},isMobile:mobile,hasTouch:mobile,deviceScaleFactor:mobile?2.75:1});
  await page.route('**/*.supabase.co/**',route=>route.abort());
  await page.goto(process.env.OKD_TEST_URL||'http://127.0.0.1:4173');
  await page.locator('#loginForm').waitFor();
  const visible=page.locator(mobile?'.login-visual-mobile':'.login-visual-desktop');
  assert(await visible.isVisible());
  assert(!(await page.locator(mobile?'.login-visual-desktop':'.login-visual-mobile').isVisible()));
  await visible.evaluate(i=>i.decode());
  assert((await visible.getAttribute('src')).endsWith(mobile?'truck_detail_92.webp':'desktop_detail_92.webp'));
  assert.equal(await visible.evaluate(i=>getComputedStyle(i).objectFit),'contain');
  assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)),'horizontal overflow');
  await page.locator('#loginEmail').fill('qa@example.invalid');
  await page.locator('#loginPass').fill('local-test-only');
  assert(await page.locator('#loginBtn').isEnabled());
  await page.locator('#forgotOpen').click();
  assert(await page.locator('#forgotForm').isVisible());
  assert.equal(await page.locator('#forgotEmail').inputValue(),'qa@example.invalid');
  await page.screenshot({path:`/tmp/checkpoint36-${name}.png`,fullPage:true});
  console.log(`PASS ${name}: correct image loaded, no crop or overflow, login inputs and recovery UI intact`);
  await page.close();
 }
}finally{await browser?.close();server.close()}
