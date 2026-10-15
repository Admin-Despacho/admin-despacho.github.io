import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const sha = process.argv[2] || process.env.GITHUB_SHA || 'unknown';
const legacyPath = 'dist/legacy/despacho-v15.js';
const legacyHash = createHash('sha256').update(readFileSync(legacyPath)).digest('hex');
const info = {
  git_sha: sha,
  built_at: new Date().toISOString(),
  carrier_flow: 'single-select-external-dispatch-v1',
  legacy_sha256: legacyHash
};
writeFileSync('dist/build-info.json', JSON.stringify(info, null, 2) + '\n');
console.log('BUILD_INFO_WRITTEN', info.git_sha, info.legacy_sha256.slice(0, 12));
