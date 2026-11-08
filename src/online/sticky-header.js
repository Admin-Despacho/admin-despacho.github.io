// V4.27 · CABECERA FIJA: calcula la altura REAL de lo que queda fijo arriba y la publica en --okd-hdr, para que pestañas,
// buscadores y filtros se fijen JUSTO debajo (sin superponerse). Notebook: barra superior (.rc4main .topbar, ahora sticky).
// Android (≤1000 px): la barra de navegación (.rc4side) ya es sticky; el título NO se fija para conservar espacio útil.
// Solo presentación: no lee ni escribe datos.
export function initStickyHeader() {
  const root = document.documentElement; let raf = 0;
  const measure = () => {
    raf = 0;
    const mobile = matchMedia('(max-width:1000px)').matches;
    const el = mobile ? document.querySelector('.rc4side') : document.querySelector('.rc4main .topbar');
    const h = el && el.getClientRects().length ? Math.ceil(el.getBoundingClientRect().height) : 0;
    if (root.style.getPropertyValue('--okd-hdr') !== h + 'px') root.style.setProperty('--okd-hdr', h + 'px');
  };
  const later = () => { if (!raf) raf = requestAnimationFrame(measure); };
  const ro = 'ResizeObserver' in window ? new ResizeObserver(later) : null;
  let seen = new Set();
  const watch = () => { if (!ro) return; document.querySelectorAll('.rc4side, .rc4main .topbar').forEach(e => { if (!seen.has(e)) { seen.add(e); ro.observe(e); } }); };
  new MutationObserver(() => { watch(); later(); }).observe(document.body, { childList: true, subtree: true });
  addEventListener('resize', later); addEventListener('orientationchange', later); watch(); measure();
}
