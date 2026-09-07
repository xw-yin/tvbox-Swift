import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { webcrypto, generateKeyPairSync } from 'node:crypto';
const requests = [];
const context = vm.createContext({
    crypto: webcrypto, __native_log() {},
    __native_request(url, options) {
        requests.push({ url, options: JSON.parse(options) });
        return JSON.stringify({ code: 200, content: '{"ok":true}', headers: {} });
    }
});
vm.runInContext(readFileSync(new URL('../../tvbox/Services/Spider/SpiderDOM.js', import.meta.url), 'utf8'), context);
const swift = readFileSync(new URL('../../tvbox/Services/Spider/DrpyRuntime.swift', import.meta.url), 'utf8');
// Decode the Swift string literal so tests exercise the actual app wrappers.
const core = swift.split('static let coreJS: String = """')[1].split('"""')[0]
    .replace(/\\\\/g, '\\').replace(/\\"/g, '"');
vm.runInContext(core, context);
context.fixture = `<div id="MainContent_newestlist"><div class="virow">
<div class="NTMitem"><div class="title"><a href='/watch?a=1&amp;b=2'>电影 &amp; &#20013;文</a></div><img src=/poster.jpg><label title=分辨率>4K</label></div>
<div class="NTMitem"><div class="title"><a href=/two>第二部</a></div></div>
</div></div><ul id=rtlist><li>第一集<li>第二集</ul>`;
const evaluate = code => vm.runInContext(code, context);
assert.equal(evaluate(`$html.elements(fixture, '#MainContent_newestlist .virow .NTMitem').length`), 2);
assert.equal(evaluate(`$html.text($html.elements(fixture, '.NTMitem')[0], '.title a')`), '电影 & 中文');
assert.equal(evaluate(`$html.text(fixture, 'label[title=分辨率]')`), '4K');
assert.equal(evaluate(`$html.attr(fixture, '.title a', 'href')`), '/watch?a=1&b=2');
assert.equal(evaluate(`$html.attr('<a href=/one>one</a>', 'href')`), '/one');
assert.equal(evaluate(`$html.attr(fixture, 'img', 'src')`), '/poster.jpg');
assert.equal(evaluate(`$html.elements(fixture, '#rtlist > li').length`), 2);
assert.equal(evaluate(`$html.text(fixture, '.NTMitem:eq(1) .title a')`), '第二部');
assert.equal(evaluate(`$html.elements(fixture, 'label, img').length`), 2);
assert.equal(evaluate(`$html.text(fixture, '.missing')`), '');
assert.equal(evaluate(`$html.attr(fixture, '.missing', 'href')`), '');
assert.equal(evaluate(`pdfh(fixture, '.NTMitem&&.title&&a&&Text')`), '电影 & 中文');
assert.equal(evaluate(`pdfa(fixture, '.NTMitem&&.title&&a').length`), 2);
assert.equal(evaluate(`pdfh('<b>Title</b>', 'Text')`), 'Title');
assert.equal(evaluate(`pdfh('<b><i>Title</i></b>', 'b&&Html')`), '<i>Title</i>');
assert.equal(evaluate(`pd(fixture, 'img&&src', 'https://example.com/path/')`), 'https://example.com/poster.jpg');
assert.equal(evaluate(`$html.text('<p>fresh</p>', 'p')`), 'fresh');
assert.equal(evaluate(`typeof require`), 'undefined');
assert.equal(evaluate(`typeof document`), 'undefined');
vm.runInContext(swift.split('static let runnerJS: String = """')[1].split('"""')[0]
    .replace(/\\\\/g, '\\').replace(/\\"/g, '"'), context);
evaluate(`
    function getConfig() { return jsonify({tabs: [{name: '电影', ext: {id: 'movie'}}]}); }
    function getCards() {
        return jsonify({list: $html.elements(fixture, '#MainContent_newestlist .virow .NTMitem').map(function(item) {
            return {title: $html.text(item, '.title a'), cover: $html.attr(item, 'img', 'src'),
                ext: {url: $html.attr(item, '.title a', 'href')}};
        })});
    }
`);
const home = JSON.parse(await evaluate('__spider_home(false)'));
assert.equal(home.class[0].type_name, '电影');
assert.equal(home.list.length, 2);
assert.equal(home.list[0].vod_name, '电影 & 中文');
assert.equal(JSON.parse(home.list[0].vod_id).url, '/watch?a=1&b=2');
assert.equal(JSON.parse(await evaluate(`__spider_category('{"id":"movie"}', 2, false, '{}')`)).list.length, 2);
console.log('24 DOM, app-wrapper, and XPTV runner regression checks passed.');

assert.equal(evaluate(`createCheerio().load('<p><b>factory</b></p>')('p b').text()`), 'factory');
assert.equal(evaluate(`createCryptoJS().MD5('abc').toString()`), '900150983cd24fb0d6963f7d28e17f72');
assert.equal(evaluate(`(() => { const C = createCryptoJS(); return C.AES.decrypt(C.AES.encrypt('roundtrip', 'pass').toString(), 'pass').toString(C.enc.Utf8); })()`), 'roundtrip');
const keys = generateKeyPairSync('rsa', { modulusLength: 1024, publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
context.keys = keys;
assert.equal(evaluate(`(() => { const RSA = loadJSEncrypt(); const enc = new RSA(); enc.setPublicKey(keys.publicKey); const dec = new RSA(); dec.setPrivateKey(keys.privateKey); return dec.decrypt(enc.encrypt('rsa-roundtrip')); })()`), 'rsa-roundtrip');
assert.equal(evaluate(`typeof $fetch.get('https://example.com').data`), 'string');
assert.equal(evaluate(`JSON.parse($fetch.get('https://example.com').data).ok`), true);
evaluate(`$fetch.post('https://example.com', 'a=1', {headers: {'X-Test':'yes'}})`);
assert.equal(requests.at(-1).options.data, 'a=1');
assert.equal(requests.at(-1).options.headers['X-Test'], 'yes');
const callJS = swift.split('static let callJS: String = """')[1].split('"""')[0];
async function call(method, args) {
    context.__spider_method = method;
    context.__spider_arguments = args;
    vm.runInContext(callJS, context);
    const result = context.__spider_completion;
    for (let i = 0; i < 100 && !result.done; i++) await Promise.resolve();
    assert.ok(result.done, 'Promise completion');
    return result;
}
evaluate(`async function getCards(ext) {
    const args = JSON.parse(ext);
    const names = await Promise.all([Promise.resolve('async'), Promise.resolve('await')]);
    return jsonify({list: [{title: names.join(' '), ext: 'string-id'}]});
}`);
let result = await call('__spider_category', ['{"id":1}', 1, false, '{}']);
assert.equal(result.error, undefined);
assert.equal(JSON.parse(result.value).list[0].vod_name, 'async await');
assert.equal(JSON.parse(result.value).list[0].vod_id, 'string-id');
context.__native_request = () => JSON.stringify({code: 403, content: 'Forbidden'});
evaluate(`async function getCards() { return await $fetch.get('https://example.com/blocked'); }`);
result = await call('__spider_home', [false]);
assert.match(result.error, /HTTP 403/);
context.__native_request = () => JSON.stringify({code: 0, error: '请求超时'});
result = await call('__spider_home', [false]);
assert.match(result.error, /请求超时/);
evaluate(`async function getCards() { throw new Error('script failure'); }`);
result = await call('__spider_home', [false]);
assert.match(result.error, /script failure/);
console.log('XPTV factories, AES/RSA, text/POST contracts, Promise.all, and error propagation checks passed.');
