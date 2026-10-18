// node driver.mjs <loader.mjs>: imports a built edge loader and reports its
// export list, its fetch handler, one run() and one fetch().
import { pathToFileURL } from 'node:url';

const mod = await import(pathToFileURL(process.argv[2]).href);
console.log(`exports ${Object.keys(mod).sort().join(',')}`);
console.log(`default.fetch: ${typeof mod.default.fetch}`);
console.log(`run ${JSON.stringify(await mod.run())}`);
const response = await mod.default.fetch(new Request('http://edge.test/'));
console.log(`fetch ${response.status} ${response.headers.get('content-type')} ${JSON.stringify(await response.text())}`);
