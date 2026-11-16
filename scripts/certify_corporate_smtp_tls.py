import json, socket, ssl, smtplib, sys
from datetime import datetime, timezone
r = {"host":"wo47.wiroos.host","port":465,"tested_at":datetime.now(timezone.utc).isoformat(),"auth_attempted":False,"mail_sent":False}
try:
    r["addresses"] = sorted({x[4][0] for x in socket.getaddrinfo(r["host"],465,proto=socket.IPPROTO_TCP)})
    with smtplib.SMTP_SSL(r["host"],465,timeout=15,context=ssl.create_default_context()) as s:
        r["tls"] = s.sock.version()
        r["certificate_verified"] = True
        r["certificate_expires"] = s.sock.getpeercert().get("notAfter")
        c, m = s.ehlo("audit.okdespacho.local")
        r["ehlo_code"] = c
        r["auth_methods"] = s.esmtp_features.get("auth")
        r["message_size_limit"] = s.esmtp_features.get("size")
        r["result"] = "PASS" if c == 250 else "FAIL"
except Exception as e:
    r.update(result="FAIL",error_type=type(e).__name__,error=str(e))
print("SMTP_TLS_RESULT " + json.dumps(r),flush=True)
sys.exit(0 if r["result"]=="PASS" else 1)
