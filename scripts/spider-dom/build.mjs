import { build } from 'esbuild';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const result = await build({
    entryPoints: [resolve(here, 'entry.js')], bundle: true, write: false,
    platform: 'browser', format: 'iife', target: 'safari14', minify: true,
    metafile: true, legalComments: 'inline'
});
writeFileSync(resolve(here, '../../tvbox/Services/Spider/SpiderDOM.js'), result.outputFiles[0].text);
const packages = new Set(Object.keys(result.metafile.inputs).map(path => {
    const match = path.replaceAll('\\', '/').match(/node_modules\/((?:@[^/]+\/)?[^/]+)/);
    return match?.[1];
}).filter(Boolean));
const licenses = [...packages].sort().map(name => {
    const root = resolve(here, 'node_modules', name);
    const pkg = JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8'));
    let license;
    for (const file of ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'LICENSE-MIT']) {
        try { license = readFileSync(resolve(root, file), 'utf8'); break; } catch {}
    }
    if (!license) {
        license = readFileSync(resolve(here, 'licenses', `${name}-LICENSE`), 'utf8');
    }
    return `${name} ${pkg.version}\n${license}`;
}).join('\n\n--------------------\n\n');
writeFileSync(resolve(here, '../../tvbox/Services/Spider/SpiderDOM-LICENSE.txt'), licenses);
