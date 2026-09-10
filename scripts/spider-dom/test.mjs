import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';

const requests = [];
const context = vm.createContext({
    crypto: webcrypto,
    __native_log() {},
    __native_request(url, options) {
        requests.push({ url, options: JSON.parse(options) });
        return JSON.stringify({ code: 200, content: '{"ok":true}', headers: {} });
    },
    __native_md5(str) { return 'md5_' + str; },
    __native_base64_encode(str) { return Buffer.from(str).toString('base64'); },
    __native_base64_decode(str) { return Buffer.from(str, 'base64').toString('utf8'); }
});

vm.runInContext(readFileSync(new URL('../../tvbox/Services/Spider/SpiderDOM.js', import.meta.url), 'utf8'), context);
const swift = readFileSync(new URL('../../tvbox/Services/Spider/DrpyRuntime.swift', import.meta.url), 'utf8');
const core = swift.split('static let coreJS: String = """')[1].split('"""')[0]
    .replace(/\\\\/g, '\\').replace(/\\"/g, '"');
vm.runInContext(core, context);

context.fixture = `<div id="MainContent_newestlist"><div class="virow">
<div class="NTMitem"><div class="title"><a href='/watch?a=1&amp;b=2'>电影 &amp; &#20013;文</a></div><img src=/poster.jpg><label title=分辨率>4K</label></div>
<div class="NTMitem"><div class="title"><a href=/two>第二部</a></div></div>
</div></div><ul id=rtlist><li>第一集<li>第二集</ul>`;

const evaluate = code => vm.runInContext(code, context);

assert.equal(evaluate(`pdfh(fixture, '.NTMitem&&.title&&a&&Text')`), '电影 & 中文');
assert.equal(evaluate(`pdfa(fixture, '.NTMitem&&.title&&a').length`), 2);
assert.equal(evaluate(`pdfh('<b>Title</b>', 'Text')`), 'Title');
assert.equal(evaluate(`pdfh('<b><i>Title</i></b>', 'b&&Html')`), '<i>Title</i>');
assert.equal(evaluate(`pd(fixture, 'img&&src', 'https://example.com/path/')`), 'https://example.com/poster.jpg');
assert.equal(evaluate(`typeof require`), 'undefined');

vm.runInContext(swift.split('static let runnerJS: String = """')[1].split('"""')[0]
    .replace(/\\\\/g, '\\').replace(/\\"/g, '"'), context);

evaluate(`
    var rule = {
        title: '测试',
        host: 'https://fixture.invalid',
        class_name: '电影&电视剧',
        class_url: 'movie&tv',
        home: function(filter) {
            return JSON.stringify({
                class: [{ type_id: 'movie', type_name: '电影' }],
                list: [{ vod_id: '1', vod_name: '测试电影', vod_pic: '/1.jpg', vod_remarks: 'HD' }]
            });
        },
        category: function(tid, pg, filter, extend) {
            return JSON.stringify({ page: parseInt(pg), pagecount: 1, limit: 10, total: 1, list: [{ vod_id: tid, vod_name: '分类影片' }] });
        },
        detail: function(id) {
            return JSON.stringify({ list: [{ vod_id: id, vod_name: '测试详情' }] });
        },
        search: function(wd, quick, pg) {
            return JSON.stringify({ list: [{ vod_id: 's1', vod_name: wd }] });
        },
        play: function(flag, id, flags) {
            return JSON.stringify({ parse: 0, url: id });
        }
    };
`);

const home = JSON.parse(await evaluate('__spider_home(false)'));
assert.equal(home.class[0].type_name, '电影');
assert.equal(home.list[0].vod_name, '测试电影');

const category = JSON.parse(await evaluate('__spider_category("movie", 1, false, "{}")'));
assert.equal(category.list[0].vod_name, '分类影片');

const detail = JSON.parse(await evaluate('__spider_detail("123")'));
assert.equal(detail.list[0].vod_name, '测试详情');

const search = JSON.parse(await evaluate('__spider_search("关键词", false, 1)'));
assert.equal(search.list[0].vod_name, '关键词');

const play = JSON.parse(await evaluate('__spider_play("flag", "https://video.m3u8", "[]")'));
assert.equal(play.url, 'https://video.m3u8');

console.log('DOM utilities and Drpy runner regression checks passed.');
