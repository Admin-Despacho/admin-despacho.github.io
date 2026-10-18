#!/usr/bin/env python3
"""Genera informes Cianbox SINTÉTICOS para QA G2: no incluye datos de clientes reales.
Salida compatible con tests/e2e/run_e2e_g2.py (OKD_FIXTURES).
Sin dependencias externas: XLSX OOXML mínimo válido con cadenas inline.
"""
import sys, zipfile, html
from pathlib import Path

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "tests/e2e/out/synthetic")
OUT.mkdir(parents=True, exist_ok=True)

def col(index):
    result = ""
    while index:
        index, rem = divmod(index - 1, 26)
        result = chr(65 + rem) + result
    return result

def write_xlsx(path, sheets):
    names = list(sheets)
    types = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
             '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
             '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
             '<Default Extension="xml" ContentType="application/xml"/>'
             '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
             + ''.join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' for i in range(1,len(names)+1))
             + '</Types>')
    workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>' + ''.join(f'<sheet name="{html.escape(n,quote=True)}" sheetId="{i}" r:id="rId{i}"/>' for i,n in enumerate(names,1)) + '</sheets></workbook>'
    rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + ''.join(f'<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i}.xml"/>' for i in range(1,len(names)+1)) + '</Relationships>'
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", types)
        z.writestr("_rels/.rels",'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        z.writestr("xl/workbook.xml",workbook)
        z.writestr("xl/_rels/workbook.xml.rels",rels)
        for n, rows in enumerate(sheets.values(),1):
            data = []
            for ri,row in enumerate(rows,1):
                cells=[]
                for ci,v in enumerate(row,1):
                    if v is None: continue
                    ref = f"{col(ci)}{ri}"
                    if isinstance(v,(int,float)) and not isinstance(v,bool):
                        cells.append(f'<c r="{ref}"><v>{v}</v></c>')
                    else:
                        cells.append(f'<c r="{ref}" t="inlineStr"><is><t>{html.escape(str(v))}</t></is></c>')
                data.append(f'<row r="{ri}">{"".join(cells)}</row>')
            z.writestr(f"xl/worksheets/sheet{n}.xml",'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'+"".join(data)+'</sheetData></worksheet>')

# Campos reales reconocidos por public/legacy/worker.js.
ph = ["Fecha","Pedido Nº","Vendedor","Estado","Cliente","Zona","Categoría Cl.","Producto","Marca","Categoría","Cant.","Moneda","Cotización","Neto U.","IVA Unit.","Subtotal Pesos","Observaciones","Factura"]
orders = [ph]
for num in range(70001,70009):
    orders.append(["2026-10-18",num,"Operador QA","COBRADO",f"CLIENTE SINTETICO {num}","MENDOZA",None,f"[QA{num}] PRODUCTO DE PRUEBA","QA","Accesorios",1,"$",1,1000,0,1000,"","FAC [B] 0020-00000001"])
    if num == 70001:
        orders.append(["2026-10-18",num,"Operador QA","COBRADO","CLIENTE SINTETICO 70001","MENDOZA",None,"[QA-EXTRA] SEGUNDO ARTICULO","QA","Accesorios",2,"$",1,500,0,1000,"","FAC [B] 0020-00000001"])
# Un envío separado como pedido; su vínculo se conserva en observación.
orders.append(["2026-10-18",70009,"Operador QA","COBRADO","CLIENTE SINTETICO 70001","MENDOZA",None,"[ENVIO-CENTRO] ENVIOS A CENTRO","QA","Varios",1,"$",1,3000,0,3000,"Pedido 70001","FAC [B] 0020-00000001"])
sh=["Cliente","Nombre fantasía","CUIT","F. Emisión","F. Vencimiento","Comprobante","Moneda","Tasa de cambio","Monto original","Ventas","Cobros","Saldo Comp.","Saldo","Vendedor","Zona"]
saldo=[sh]
ch=["Cliente","Nombre fantasía","CUIT","Saldo Anterior","Ventas","Cobros","Saldo","Vendedor Asignado","Localidad","Provincia","Teléfono"]
ctacte=[ch]
for num in range(70001,70009):
    name=f"CLIENTE SINTETICO {num}"
    saldo.append([name,name,f"2099000{num}","2026-10-18","2026-10-28","FAC [B] 0020-00000001","Peso",1,1000,1000,0,1000,1000,"Operador QA","MENDOZA"])
    ctacte.append([name,name,f"2099000{num}",0,1000,0,1000,"Operador QA","Ciudad de Mendoza","Mendoza","0000000000"])
write_xlsx(OUT/"informe_pedidos__31_.xlsx",{"pedidos":orders})
write_xlsx(OUT/"SALDO_COMPROBANTE__3_.xlsx",{"Clientes":saldo})
write_xlsx(OUT/"SALDO_CUENTA_CORRIENTE.xlsx",{"Clientes":ctacte})
print("3 fixtures XLSX sintéticos creados en",OUT)
