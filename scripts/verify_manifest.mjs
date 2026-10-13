// Verifica DELIVERY_MANIFEST.json: archivos existentes, hashes, versión = package.json. Sale con 1 si hay problemas.
import { verifyManifest } from './manifest_lib.mjs';
const v = verifyManifest(process.cwd()); console.log(JSON.stringify(v, null, 1)); process.exit(v.ok ? 0 : 1);
