# Spider DOM runtime

The checked-in `tvbox/Services/Spider/SpiderDOM.js` bundles Cheerio's slim
HTML parser and CSS selector engine for JavaScriptCore. It needs no Node.js,
browser DOM, or network at app runtime. Both app targets include it and its
license notices as resources. XcodeGen also discovers these resources under
the existing `tvbox` source path.

Rebuild from the repository root:

```sh
npm ci --prefix scripts/spider-dom
node scripts/spider-dom/build.mjs
node scripts/spider-dom/test.mjs
node scripts/spider-dom/test-xptv.mjs
```

Commit the rebuilt bundle and license notices together with dependency changes.
The tests load the shipped bundle and decode the app's actual Swift core JS
wrapper, exercising nested selectors, attributes, entities, malformed HTML,
Drpy selector chains, empty matches, and fragment extraction without browser globals.
These Node VM checks do not replace iOS JavaScriptCore/device testing.

`test-xptv.mjs` downloads four unchanged scripts from `xptv_sources.json` into
`.build/xptv-debug` and runs their actual async entry points against fixed HTTP
responses. It tests `$html`, `createCheerio`, `createCryptoJS`, and the scripts
that explicitly use `JSON.parse(ext)` / `JSON.parse(data)`.
The iOS CI job also compiles `JavaScriptCoreSmoke.swift` with the actual Swift
runtime and checks Promise settlement on Apple's JavaScriptCore before packaging.

The bundle also supplies CryptoJS and JSEncrypt factories used by XPTV.
CryptoJS and RSA entropy comes from the app's native secure random bridge.
Async source is executed unchanged; the app waits for a per-call Promise result.

`pdfa` returns outer HTML strings. `pdfh` returns the first match's text,
inner HTML, or attribute; missing matches return an empty string. CSS syntax
errors throw instead of silently returning an unrelated page's text.

Cheerio documentation: https://cheerio.js.org/docs/basics/selecting/
The boolbase npm package omits its license file; the copy under `licenses/`
comes from https://raw.githubusercontent.com/fb55/boolbase/master/LICENSE.
