// Exercise unchanged upstream scripts with deterministic HTTP responses.
// Downloaded source stays in .build; only fixtures/harness belong to this repo.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import vm from 'node:vm';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
const root = resolve(import.meta.dirname, '../..');
const cache = resolve(root, '.build/xptv-debug');
mkdirSync(cache, { recursive: true });
const swift = readFileSync(resolve(root, 'tvbox/Services/Spider/DrpyRuntime.swift'), 'utf8');
const script = name => swift.split(`static let ${name}: String = """`)[1].split('"""')[0]
    .replace(/\\\\/g, '\\').replace(/\\"/g, '"');
const dom = readFileSync(resolve(root, 'tvbox/Services/Spider/SpiderDOM.js'), 'utf8');
const fixtures = {
    xptv_aowu: JSON.stringify({list:[{vod_id:1,vod_name:'测试电影',vod_pic:'/1.jpg',vod_remarks:'更新',url:'/detail/1'}]}),
    xptv_duanjutt: `<div class="dropdown-box"><ul><li><a href="/type/latest.html">最近更新</a></li></ul></div><ul class="myui-vodlist"><li><a class="myui-vodlist__thumb" href="/detail/1.html" title="测试电影" data-original="/1.jpg"></a><span class="pic-text">更新</span></li></ul>`,
    xptv_4kav: `<div id=MainContent_newestlist><div class=virow><div class=NTMitem><div class=title><a href=/movie/1><h2>测试电影</h2></a></div><div class=poster><img src=/1.jpg></div><label title=分辨率>4K</label></div></div></div><div id=MainContent_header_nav><span class=page-number>1/10</span></div>`,
    xptv_anfuns: `<div class=hl-list-item><a class=hl-item-thumb href=/vod/1 data-original=/1.jpg></a><h2 class=hl-item-title>测试电影</h2><span class=remarks>更新</span></div>`,
    xptv_apple: JSON.stringify({ data: [{ id: 1, name: '测试电影', pic: '/1.jpg', state: '更新' }] }),
    xptv_jianpian: JSON.stringify({ data: [{ title: '测试电影', jump_id: 1, thumbnail: '/1.jpg' }] })
};
const sites = JSON.parse(readFileSync(resolve(root, 'xptv_sources.json'))).sites;
for (const [key, fixture] of Object.entries(fixtures)) {
    const site = sites.find(site => site.key === key);
    const path = resolve(cache, `${key}.js`);
    if (!existsSync(path)) {
        const response = await fetch(site.api, { signal: AbortSignal.timeout(15000) });
        assert.ok(response.ok, `${key}: script download HTTP ${response.status}`);
        writeFileSync(path, await response.text());
    }
    const calls = [];
    const context = vm.createContext({
        $config_str: '{}', __native_log() {},
        __native_md5(value) { return createHash('md5').update(value).digest('hex'); },
        __native_request(url, options) {
            const parsed = JSON.parse(options);
            calls.push({ url, options: parsed });
            if (key === 'xptv_aowu') {
                assert.equal(parsed.method, 'POST');
                assert.equal(typeof parsed.data, 'string', 'aowu must send form bytes rather than JSON');
                const form = new URLSearchParams(parsed.data);
                assert.equal(form.get('type'), '20');
                assert.equal(form.get('page'), '1');
                assert.equal(form.get('class'), '');
                assert.equal(form.get('key'), createHash('md5').update('DS' + form.get('time') + 'DCC147D11943AF75').digest('hex'));
            }
            return JSON.stringify({ code: 200, content: fixture, headers: {} });
        }
    });
    for (const source of [dom, script('coreJS'), readFileSync(path, 'utf8'), script('runnerJS')]) {
        vm.runInContext(source, context, { timeout: 2000 });
    }
    context.__spider_method = '__spider_home';
    context.__spider_arguments = [false];
    vm.runInContext(script('callJS'), context);
    for (let i = 0; i < 100 && !context.__spider_completion.done; i++) await Promise.resolve();
    assert.ok(context.__spider_completion.done, `${key}: Promise did not settle`);
    assert.equal(context.__spider_completion.error, undefined, key);
    const home = JSON.parse(context.__spider_completion.value);
    assert.ok(home.class.length > 0, `${key}: categories`);
    assert.equal(home.list[0]?.vod_name, '测试电影', `${key}: card mapping`);
    assert.ok(calls.length > 0, `${key}: HTTP bridge`);
    console.log(`${key}: unchanged async source → HTTP fixture → ${home.list.length} card(s), ${home.class.length} categories`);
}
