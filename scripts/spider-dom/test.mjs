import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const context = vm.createContext({ __native_log() {} });
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
const home = JSON.parse(evaluate('__spider_home(false)'));
assert.equal(home.class[0].type_name, '电影');
assert.equal(home.list.length, 2);
assert.equal(home.list[0].vod_name, '电影 & 中文');
assert.equal(JSON.parse(home.list[0].vod_id).url, '/watch?a=1&b=2');
assert.equal(JSON.parse(evaluate(`__spider_category('{"id":"movie"}', 2, false, '{}')`)).list.length, 2);
console.log('24 DOM, app-wrapper, and XPTV runner regression checks passed.');
