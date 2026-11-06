"""Análisis del padrón de clientes (listado_clientes.xlsx) con las MISMAS reglas que la importación del servidor (V4.26).
Uso: python3 tools/analizar_padron_clientes.py <padron.xlsx> <carpeta_salida>   ·   No modifica nada: solo lee y escribe informes."""
import sys, re, json, unicodedata, collections, openpyxl
EMAIL = re.compile(r'^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$', re.I)
def norm_name(s):   # = Normalizer.name del constructor: sin acentos, MAYÚSCULAS, solo A-Z0-9 separados por un espacio
    s = unicodedata.normalize('NFD', str(s or '')); s = ''.join(c for c in s if unicodedata.category(c) != 'Mn').upper()
    return re.sub(r'[^A-Z0-9]+', ' ', s).strip()
def cuit_ok(c):
    if not re.fullmatch(r'\d{11}', c): return False
    w = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]; t = sum(int(c[i]) * w[i] for i in range(10)); r = 11 - t % 11
    if r == 10: return False   # AFIP no emite estos CUIT (cambia el prefijo): igual que _cuit_valid del servidor
    return (0 if r == 11 else r) == int(c[10])
def emails_of(cell):
    parts = [p.strip().strip('.').lower() for p in re.split(r'[;,/\s]+', str(cell or '')) if p.strip()]
    return [p for p in parts if EMAIL.match(p)], [p for p in parts if not EMAIL.match(p)]
def analyze(path):
    ws = openpyxl.load_workbook(path, read_only=True, data_only=True).worksheets[0]; rows = list(ws.iter_rows(values_only=True))
    head = [str(h or '').strip().lower() for h in rows[0]]; col = lambda *n: next(i for i, h in enumerate(head) if any(x in h for x in n))
    iR, iN, iT, iD, iE = col('raz'), col('nombre'), col('tipo'), col('mero', 'numero'), col('mail')
    recs = []
    for k, r in enumerate(rows[1:], start=2):
        rs, nm, td, doc, em = (str(r[i] or '').strip() if i < len(r) else '' for i in (iR, iN, iT, iD, iE))
        doc = re.sub(r'\D', '', doc); ok, bad = emails_of(em)
        if not (rs or nm or doc or em): continue   # fila completamente vacía (el archivo trae una al final): no es un cliente
        recs.append(dict(fila=k, razon_social=rs, nombre=nm, tipo_doc=td.upper(), documento=doc, email_original=em, email=ok[0] if ok else None, emails_extra=ok[1:], emails_invalidos=bad))
    # claves por nombre: cada nombre normalizado (razón social y nombre) → conjunto de filas
    by_name = collections.defaultdict(set)
    for x in recs:
        for n in {norm_name(x['razon_social']), norm_name(x['nombre'])} - {''}: by_name[n].add(x['fila'])
    # una MISMA clave (CUIT o DNI) con correos DISTINTOS es ambigua: no se asocia NINGUNA de sus filas
    by_doc = collections.defaultdict(set)
    for x in recs:
        if x['email'] and x['documento']: by_doc[x['documento']].add(x['email'])
    out = dict(cuit=[], dni=[], nombre=[], pendientes=[], sin_email=[], invalidos=[])
    # un documento con correos DISTINTOS indica un error de datos: esas filas tampoco se asocian por nombre (coincidencia dudosa)
    uniq_names = lambda x: [] if (x['documento'] and len(by_doc.get(x['documento'], ())) > 1) else [n for n in sorted({norm_name(x['razon_social']), norm_name(x['nombre'])} - {''}) if len(by_name[n]) == 1 and len(n.split()) >= 2]
    seen_cuit, seen_dni = {}, {}
    for x in recs:
        if not x['email']:
            (out['invalidos'] if x['emails_invalidos'] else out['sin_email']).append(dict(x, motivo='correo inválido' if x['emails_invalidos'] else 'sin correo')); continue
        if x['emails_extra']: out['pendientes'].append(dict(x, motivo='varios correos: se sugiere el primero; los otros quedan para revisión', importado=True))
        d, t = x['documento'], x['tipo_doc']
        if t.startswith('CUIT') or t.startswith('CUIL') or len(d) == 11:
            if cuit_ok(d):
                if len(by_doc[d]) > 1: out['pendientes'].append(dict(x, motivo='CUIT repetido con correos distintos: no se asocia ninguna fila', importado=False)); continue
                if d in seen_cuit: continue   # misma clave y mismo correo: una sola asociación
                seen_cuit[d] = x['email']; out['cuit'].append(x); continue
            out['pendientes'].append(dict(x, motivo='CUIT/CUIL con dígito verificador inválido: se intenta por nombre', importado=False))
        elif t.startswith('DNI') or re.fullmatch(r'\d{7,8}', d):
            if re.fullmatch(r'\d{7,8}', d):
                if len(by_doc[d]) > 1: out['pendientes'].append(dict(x, motivo='DNI repetido con correos distintos: no se asocia ninguna fila', importado=False)); continue
                if d in seen_dni: continue
                seen_dni[d] = x['email']; out['dni'].append(x); continue
            out['pendientes'].append(dict(x, motivo='DNI con formato inválido: se intenta por nombre', importado=False))
        out['sin_documento_valido'] = out.get('sin_documento_valido', 0) + 1
        if not uniq_names(x): out['pendientes'].append(dict(x, motivo='sin documento válido y nombre ambiguo, repetido o de una sola palabra: no se asocia', importado=False))
    amb = {}
    for x in recs:
        if not x['email']: continue
        u = uniq_names(x)
        if u: out['nombre'].append(dict(fila=x['fila'], razon_social=x['razon_social'], nombre=x['nombre'], email=x['email'], claves_nombre=u))
        for n in sorted({norm_name(x['razon_social']), norm_name(x['nombre'])} - {''}):
            if len(by_name[n]) > 1: amb.setdefault(n, set()).update(by_name[n])
    out['nombres_ambiguos'] = {n: sorted(f) for n, f in amb.items()}
    return recs, out
if __name__ == '__main__':
    recs, out = analyze(sys.argv[1]); import os; os.makedirs(sys.argv[2], exist_ok=True)
    json.dump(out, open(os.path.join(sys.argv[2], 'analisis_padron.json'), 'w'), ensure_ascii=False, indent=1)
    print(json.dumps({'filas': len(recs), 'con_correo_valido': sum(1 for r in recs if r['email']), 'por_CUIT': len(out['cuit']), 'por_DNI': len(out['dni']), 'clientes_con_clave_por_NOMBRE_inequivoco': len(out['nombre']), 'claves_de_nombre': sum(len(x['claves_nombre']) for x in out['nombre']), 'nombres_ambiguos_no_asociados': len(out['nombres_ambiguos']),
                      'pendientes_revision': len(out['pendientes']), 'no_asociados_de_pendientes': sum(1 for p in out['pendientes'] if not p.get('importado')),
                      'sin_correo': len(out['sin_email']), 'correo_invalido': len(out['invalidos'])}, ensure_ascii=False, indent=1))
    print('motivos de pendientes:', dict(collections.Counter(p['motivo'] for p in out['pendientes'])))

def rows_for_import(out):
    """Filas que se envían a client_padron_import (el servidor las vuelve a validar): CUIT, DNI y claves de NOMBRE inequívocas."""
    rows = [dict(fila=x['fila'], tipo='CUIT', clave=x['documento'], email=x['email'], nombre=x['razon_social'] or x['nombre']) for x in out['cuit']]
    rows += [dict(fila=x['fila'], tipo='DNI', clave=x['documento'], email=x['email'], nombre=x['razon_social'] or x['nombre']) for x in out['dni']]
    rows += [dict(fila=x['fila'], tipo='NOMBRE', clave=k, email=x['email'], nombre=x['razon_social'] or x['nombre']) for x in out['nombre'] for k in x['claves_nombre']]
    return rows
def conciliacion(recs, out):
    cu = {x['fila'] for x in out['cuit']}; dn = {x['fila'] for x in out['dni']}; nm = {x['fila'] for x in out['nombre']}
    val = [r for r in recs if r['email']]
    por = {'CUIT': 0, 'DNI': 0, 'SOLO NOMBRE': 0, 'NO ASOCIADO': 0}
    for r in val: por['CUIT' if r['fila'] in cu else 'DNI' if r['fila'] in dn else 'SOLO NOMBRE' if r['fila'] in nm else 'NO ASOCIADO'] += 1
    dup = sum(1 for r in val if r['fila'] not in cu and r['fila'] not in dn and r['documento'] and any(p['fila'] == r['fila'] and 'correos distintos' in p['motivo'] for p in out['pendientes']))
    return [('Clientes del padrón (sin la fila vacía final)', len(recs)), ('  = con correo válido + sin correo + correo inválido', f"{len(val)} + {len(out['sin_email'])} + {len(out['invalidos'])} = {len(val) + len(out['sin_email']) + len(out['invalidos'])}"),
            ('Los clientes con correo válido se asocian por (cada cliente se cuenta UNA vez):', ''), ('  · CUIT/CUIL', por['CUIT']), ('  · DNI', por['DNI']), ('  · solo por nombre exacto (sin documento válido)', por['SOLO NOMBRE']),
            ('  · NO asociados (documento repetido con correos distintos, o sin documento y nombre ambiguo)', por['NO ASOCIADO']), ('  = total', f"{sum(por.values())} (= {len(val)})"),
            ('Claves de nombre: ADEMÁS del documento, un cliente puede asociarse por su razón social Y por su nombre de contacto', f"{sum(len(x['claves_nombre']) for x in out['nombre'])} claves de {len(out['nombre'])} clientes"),
            ('Filas enviadas al servidor = CUIT + DNI + claves de nombre', f"{len(out['cuit'])} + {len(out['dni'])} + {sum(len(x['claves_nombre']) for x in out['nombre'])} = {len(out['cuit']) + len(out['dni']) + sum(len(x['claves_nombre']) for x in out['nombre'])}"),
            ('Correos existentes (los 47 actuales, manuales o importados)', 'se CONSERVAN: si una clave ya tiene correo, la fila del padrón se cuenta como «conservada» y no se escribe')]
def write_report(recs, out, path):
    import openpyxl
    from openpyxl.styles import Font, PatternFill
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = 'RESUMEN'
    imp = rows_for_import(out)
    for r in [('INFORME DE IMPORTACIÓN DEL PADRÓN DE CLIENTES (vista previa: NO se importó nada)',), (), ('Filas del padrón', len(recs)), ('Con correo válido', sum(1 for r in recs if r['email'])),
              ('Asociables por CUIT/CUIL (dígito verificador válido)', len(out['cuit'])), ('Asociables por DNI', len(out['dni'])),
              ('Claves por nombre exacto e inequívoco', sum(len(x['claves_nombre']) for x in out['nombre'])), ('  · clientes con al menos una clave de nombre', len(out['nombre'])),
              ('Nombres ambiguos (NO se asocian)', len(out['nombres_ambiguos'])), ('Pendientes de revisión', len(out['pendientes'])), ('Sin correo', len(out['sin_email'])), ('Correo inválido', len(out['invalidos'])),
              ('Filas que se envían al servidor para importar', len(imp)), (),
              ('CONCILIACIÓN DE TOTALES',), *conciliacion(recs, out), (),
              ('Reglas', 'CUIT/CUIL con dígito verificador; DNI de 7 u 8 dígitos; nombre/razón social normalizado igual al constructor, ÚNICO en el padrón y de 2+ palabras.'),
              ('Modo', 'CONSERVAR: nunca se pisa un correo existente (los 47 actuales, manuales o importados).')]:
        ws.append(list(r))
    ws['A1'].font = Font(bold=True, size=13); ws.column_dimensions['A'].width = 58; ws.column_dimensions['B'].width = 70
    def sheet(name, cols, data):
        s = wb.create_sheet(name); s.append(cols)
        for c in s[1]: c.font = Font(bold=True, color='FFFFFF'); c.fill = PatternFill('solid', fgColor='07151B')
        for d in data: s.append([d.get(k) if not isinstance(d.get(k), list) else ' · '.join(d.get(k)) for k in cols])
        for i, c in enumerate(cols): s.column_dimensions[openpyxl.utils.get_column_letter(i + 1)].width = 16 if c in ('fila', 'tipo', 'tipo_doc') else 34
    sheet('A IMPORTAR', ['fila', 'tipo', 'clave', 'email', 'nombre'], imp)
    sheet('PENDIENTES DE REVISIÓN', ['fila', 'razon_social', 'nombre', 'tipo_doc', 'documento', 'email_original', 'motivo'], out['pendientes'])
    sheet('NOMBRES AMBIGUOS', ['nombre_normalizado', 'filas'], [dict(nombre_normalizado=n, filas=[str(f) for f in fs]) for n, fs in sorted(out['nombres_ambiguos'].items())])
    sheet('SIN CORREO', ['fila', 'razon_social', 'nombre', 'tipo_doc', 'documento'], out['sin_email'])
    sheet('CORREO INVÁLIDO', ['fila', 'razon_social', 'nombre', 'tipo_doc', 'documento', 'email_original'], out['invalidos'])
    wb.save(path)
if __name__ == '__main__' and len(sys.argv) > 2:
    import os
    recs, out = analyze(sys.argv[1])
    write_report(recs, out, os.path.join(sys.argv[2], 'INFORME_IMPORTACION_PADRON.xlsx'))
    json.dump(rows_for_import(out), open(os.path.join(sys.argv[2], 'filas_para_importar.json'), 'w'), ensure_ascii=False)
    print('informe:', os.path.join(sys.argv[2], 'INFORME_IMPORTACION_PADRON.xlsx'), '· filas para importar:', len(rows_for_import(out)))
