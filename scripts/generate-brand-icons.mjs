// Íconos PWA ligeros, sin dependencias externas. Monograma aprobado OK negro sobre blanco.
import fs from 'node:fs';
import zlib from 'node:zlib';
const path='public/icons';
const contours=[
'406:185,391:170,366:172,313:219,293:244,283:219,267:199,241:183,220:178,220:217,236:227,247:241,251:270,243:287,227:302,212:309,187:312,150:299,137:285,131:270,136:241,164:217,164:178,125:193,100:219,89:247,90:282,105:312,129:333,166:347,199:349,235:341,264:324,282:303,294:272,314:296,366:342,388:345,406:330,407:311,351:254,401:206',
'178:149,174:153,174:249,178:253,206:253,210:249,210:153,206:149'
].map(s=>s.split(',').map(p=>p.split(':').map(Number)));
function inside(x,y,p){let hit=false;for(let i=0,j=p.length-1;i<p.length;j=i++){const a=p[i],b=p[j];if((a[1]>y)!==(b[1]>y)&&x<(b[0]-a[0])*(y-a[1])/(b[1]-a[1])+a[0])hit=!hit;}return hit;}
function crc32(buf){let c=-1;for(const b of buf){c^=b;for(let i=0;i<8;i++)c=(c>>>1)^((c&1)?0xedb88320:0);}return (c^-1)>>>0;}
function chunk(type,bytes){const name=Buffer.from(type);const n=Buffer.alloc(4);n.writeUInt32BE(bytes.length);const crc=Buffer.alloc(4);crc.writeUInt32BE(crc32(Buffer.concat([name,bytes])));return Buffer.concat([n,name,bytes,crc]);}
function png(size){const raw=Buffer.alloc((size*4+1)*size);for(let y=0;y<size;y++){const row=y*(size*4+1);raw[row]=0;for(let x=0;x<size;x++){let black=0;for(const [dx,dy] of [[.25,.25],[.75,.25],[.25,.75],[.75,.75]]){const u=(x+dx)*512/size,v=(y+dy)*512/size;if(inside(u,v,contours[0])||inside(u,v,contours[1]))black++;}const color=Math.round(255*(1-black/4));const i=row+1+x*4;raw[i]=raw[i+1]=raw[i+2]=color;raw[i+3]=255;}}const ih=Buffer.alloc(13);ih.writeUInt32BE(size,0);ih.writeUInt32BE(size,4);ih[8]=8;ih[9]=6;return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',ih),chunk('IDAT',zlib.deflateSync(raw,{level:9})),chunk('IEND',Buffer.alloc(0))]);}
fs.mkdirSync(path,{recursive:true});
for(const [name,n] of [['icon-16.png',16],['icon-32.png',32],['apple-touch-icon.png',180],['icon-192.png',192],['icon-512.png',512],['icon-maskable-192.png',192],['icon-maskable-512.png',512]])fs.writeFileSync(path+'/'+name,png(n));
console.log('Iconos OK negro/blanco generados: favicon, Apple, PWA y maskable.');
