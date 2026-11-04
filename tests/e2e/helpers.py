"""Ayudas E2E (Fase 2B.3): resolver una parada con receptor, firma táctil, CUIL, cobranza y ubicación."""
async def sign(pg, sel):
    """V4.19: FIRMAR abre la firma a pantalla completa; se firma ahí y se toca CONFIRMAR FIRMA.
    sel puede apuntar al formulario o a su antiguo lienzo '[data-sig]' (compatibilidad: se usa el botón FIRMAR de ese formulario)."""
    opener = sel.replace('[data-sig]', '[data-sigopen]') if '[data-sig]' in sel else sel + ' >> [data-sigopen]'
    await pg.click(opener); await pg.wait_for_selector('.drv-sign-modal [data-sigpad]'); await pg.wait_for_timeout(150)
    b = await pg.locator('.drv-sign-modal [data-sigpad]').bounding_box()
    await pg.mouse.move(b['x'] + b['width'] * .15, b['y'] + b['height'] * .55); await pg.mouse.down()
    await pg.mouse.move(b['x'] + b['width'] * .45, b['y'] + b['height'] * .35, steps=8); await pg.mouse.move(b['x'] + b['width'] * .8, b['y'] + b['height'] * .6, steps=8); await pg.mouse.up()
    await pg.click('.drv-sign-modal [data-sigok]'); await pg.wait_for_selector('.drv-sign-modal', state='detached')

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
