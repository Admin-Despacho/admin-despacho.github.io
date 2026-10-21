#!/usr/bin/env python3
"""Informes Cianbox SINTÉTICOS (sin datos reales) para la prueba de saldo ausente / importe manual / NOC automática / bultos.
Reproduce la FORMA del caso real (pedidos facturados después de exportar la cuenta corriente) con clientes inventados.
Uso: python3 tests/e2e/generate_synthetic_saldo_noc.py [carpeta]   (por defecto tests/e2e/out/synthetic_saldo)"""
import sys
from pathlib import Path
# --decimales: NOC con centavos ($300,50 y $1.234,56) para probar que el importe se conserva exacto
DEC = '--decimales' in sys.argv; sys.argv = [a for a in sys.argv if a != '--decimales']
if len(sys.argv) < 2: sys.argv.append('tests/e2e/out/synthetic_saldo')
src = Path(__file__).with_name('generate_synthetic_excel.py').read_text(encoding='utf-8')
ns = {'__name__': 'gen'}; exec(src.split('# Campos reales reconocidos')[0], ns)   # reutiliza col() y write_xlsx() del generador base
write_xlsx, OUT = ns['write_xlsx'], Path(sys.argv[1]); OUT.mkdir(parents=True, exist_ok=True)
ph = ["Fecha","Pedido Nº","Vendedor","Estado","Cliente","Zona","Categoría Cl.","Producto","Marca","Categoría","Cant.","Moneda","Cotización","Neto U.","IVA Unit.","Subtotal Pesos","Observaciones","Factura"]
C = {  # pedido: (cliente, cuit, comprobante en el informe de pedidos)
  72001: ("CLIENTE QA SALDO AUSENTE", "20990072001", "NDP [X] 0020-00072001"),   # comprobante que NO está en Saldo Comprobante (caso real: pedido facturado después de exportar)
  72002: ("CLIENTE QA SIN COMPROBANTE", "20990072002", None),                      # sin comprobante: no facturado al exportar (caso real: pedido sin comprobante al exportar)
  72003: ("CLIENTE QA NOC NUEVA", "20990072003", "FAC [B] 0020-00072003"),         # NOC abierta NO reflejada en la cuenta corriente → se aplica sola
  72004: ("CLIENTE QA NOC REFLEJADA", "20990072004", "FAC [B] 0020-00072004"),     # NOC ya reflejada en la cuenta corriente → no se aplica de nuevo
}
if DEC: C[72005] = ("CLIENTE QA NOC CENTAVOS", "20990072005", "FAC [B] 0020-00072005")   # NOC $1.234,56 no reflejada
NOC903 = 300.5 if DEC else 300
orders = [ph]
for num, (name, cuit, comp) in C.items():
    imp = 2000 if num == 72005 else 1000
    orders.append(["2026-10-20", num, "Operador QA", "Facturado ZONA ESTE", name, "01 ZONA ESTE - QA", None, f"[QA{num}] PRODUCTO DE PRUEBA", "QA", "Accesorios", 1, "$", 1, imp, 0, imp, "", comp])
sh = ["Cliente","Nombre fantasía","CUIT","F. Emisión","F. Vencimiento","Comprobante","Moneda","Tasa de cambio","Monto original","Ventas","Cobros","Saldo Comp.","Saldo","Vendedor","Zona"]
saldo = [sh]
for num in (72003, 72004) + ((72005,) if DEC else ()):
    name, cuit, comp = C[num]; imp = 2000 if num == 72005 else 1000
    saldo.append([name, name, cuit, "2026-10-20", "2026-10-30", comp, "Peso", 1, imp, imp, 0, imp, 0, "Operador QA", "ZONA ESTE"])
name, cuit, _ = C[72003]; saldo.append([name, name, cuit, "2026-10-15", "2026-10-25", "NOC [X] 0020-00000903", "Peso", 1, -NOC903, -NOC903, 0, -NOC903, 0, "Operador QA", "ZONA ESTE"])
if DEC: name, cuit, _ = C[72005]; saldo.append([name, name, cuit, "2026-10-15", "2026-10-25", "NOC [X] 0020-00000905", "Peso", 1, -1234.56, -1234.56, 0, -1234.56, 0, "Operador QA", "ZONA ESTE"])
name, cuit, _ = C[72004]; saldo.append([name, name, cuit, "2026-10-15", "2026-10-25", "NOC [X] 0020-00000904", "Peso", 1, -200, -200, 0, -200, 0, "Operador QA", "ZONA ESTE"])
ch = ["Cliente","Nombre fantasía","CUIT","Saldo Anterior","Ventas","Cobros","Saldo","Vendedor Asignado","Localidad","Provincia","Teléfono"]
ctacte = [ch]
for num, (name, cuit, _) in C.items():
    s = {72001: 5000, 72002: 5000, 72003: 1000, 72004: 800, 72005: 2000}[num]   # 72005: NOC no reflejada   # 72003: la NOC no está reflejada · 72004: ya reflejada (1000 − 200)
    ctacte.append([name, name, cuit, 0, s, 0, s, "Operador QA", "San Martín", "Mendoza", "0000000000"])
write_xlsx(OUT / "informe_pedidos_qa.xlsx", {"pedidos": orders})
write_xlsx(OUT / "saldo_comprobante_qa.xlsx", {"Clientes": saldo})
write_xlsx(OUT / "saldo_cuenta_corriente_qa.xlsx", {"Clientes": ctacte})
print("3 informes sintéticos (saldo/NOC) en", OUT)
