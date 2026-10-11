"""Ayudas E2E (Fase 2B.3): resolver una parada con receptor, firma táctil, CUIL, cobranza y ubicación."""
async def sign(pg, sel):
    b = await pg.locator(sel).bounding_box()
    await pg.mouse.move(b['x'] + 20, b['y'] + 30); await pg.mouse.down()
    await pg.mouse.move(b['x'] + 140, b['y'] + 80, steps=6); await pg.mouse.move(b['x'] + 200, b['y'] + 40, steps=4); await pg.mouse.up()

async def resolve(pg, i, outcome, note=None, cuil='20123456786', cobro=None, save=True):
    box = f'.drv-stop >> nth={i}'
    await pg.click(f'{box} >> [data-o="{outcome}"]')
    if outcome in ('ENTREGADO', 'ENTREGA_PARCIAL'):
        await pg.fill(f'{box} >> [data-f="recv"]', 'Receptor Prueba'); await sign(pg, f'{box} >> [data-sig]')
        if await pg.locator(f'{box} >> [data-f="cuil"]').count():
            await pg.fill(f'{box} >> [data-f="cuil"]', cuil); await pg.dispatch_event(f'{box} >> [data-f="cuil"]', 'change'); await pg.wait_for_timeout(200)
    if await pg.locator(f'{box} >> [data-f="cst"]').count():
        st = cobro or ('COBRADO' if outcome in ('ENTREGADO', 'ENTREGA_PARCIAL') else 'NO_COBRADO')
        await pg.select_option(f'{box} >> [data-f="cst"]', st)
        if st != 'NO_COBRADO': await pg.fill(f'{box} >> [data-f="camt"]', '1000'); await pg.select_option(f'{box} >> [data-f="cmode"]', 'EFECTIVO')
        if st != 'COBRADO': await pg.fill(f'{box} >> [data-f="cnote"]', 'Paga después')
    if note: await pg.fill(f'{box} >> [data-f="txt"]', note)
    if save: await pg.click(f'{box} >> [data-save]'); await pg.wait_for_timeout(700)
