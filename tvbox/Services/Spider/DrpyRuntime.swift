import Foundation

/// Drpy 与 CatVod 规范的 JavaScript 运行时支撑环境
struct DrpyRuntime {
    /// A separate completion object per call prevents a late Promise from
    /// overwriting the next call's result after a timeout.
    static let callJS: String = """
    var __spider_completion = { done: false };
    (function(completion, method, args) {
        Promise.resolve().then(function() {
            if (typeof globalThis[method] !== 'function') throw new Error('缺少接口 ' + method);
            return globalThis[method].apply(null, args);
        }).then(function(value) {
            completion.value = typeof value === 'string' ? value : JSON.stringify(value);
            completion.done = true;
        }).catch(function(error) {
            completion.error = __spider_errorMessage(error);
            completion.done = true;
        });
    })(__spider_completion, __spider_method, __spider_arguments);
    """

    /// 注入到 JSContext 中的基础运行环境与 DOM 工具库
    static let coreJS: String = """
    // JavaScriptCore stacks omit Error.message; keep the actionable cause first.
    function __spider_errorMessage(error) {
        var message = String(error && error.message || error);
        var stack = error && error.stack ? String(error.stack) : '';
        return stack && stack.indexOf(message) < 0 ? message + '\\n' + stack : (stack || message);
    }

    // 基础控制台重定向
    if (typeof console === 'undefined') {
        console = {};
    }
    console.log = function() {
        var args = Array.prototype.slice.call(arguments);
        __native_log(args.map(function(a) {
            return typeof a === 'object' ? JSON.stringify(a) : String(a);
        }).join(' '));
    };
    console.error = console.log;
    console.warn = console.log;
    console.info = console.log;

    // 本地存储模拟
    var local = {
        _data: {},
        get: function(k, def) {
            var v = this._data[k];
            return v !== undefined ? v : (def || '');
        },
        set: function(k, v) {
            this._data[k] = v;
        },
        delete: function(k) {
            delete this._data[k];
        }
    };

    // 加解密快捷函数
    function md5(str) {
        return __native_md5(String(str));
    }
    function base64Encode(str) {
        return __native_base64_encode(String(str));
    }
    function base64Decode(str) {
        return __native_base64_decode(String(str));
    }

    // 网络请求封装
    function req(url, options) {
        options = options || {};
        var resStr = __native_request(url, JSON.stringify(options));
        try {
            return JSON.parse(resStr);
        } catch (e) {
            return { content: resStr, code: 200, headers: {} };
        }
    }
    var request = req;

    function fetch(url, options) {
        var res = req(url, options);
        return {
            status: res.code || 200,
            ok: (res.code >= 200 && res.code < 300),
            text: function() { return Promise.resolve(res.content || ''); },
            json: function() {
                try {
                    return Promise.resolve(JSON.parse(res.content));
                } catch(e) {
                    return Promise.reject(e);
                }
            }
        };
    }

    // XPTV 扩展规范内置对象与工具函数
    function argsify(arg) {
        if (typeof arg === 'object' && arg !== null) return arg;
        if (typeof arg === 'string') {
            try { return JSON.parse(arg); } catch(e) { return {}; }
        }
        return {};
    }

    function jsonify(obj) {
        if (typeof obj === 'string') return obj;
        return JSON.stringify(obj);
    }

    var $print = console.log;

    var $cache = {
        _d: {},
        get: function(k) { return this._d[k]; },
        set: function(k, v) { this._d[k] = v; }
    };

    var $utils = {
        toastInfo: function(msg) { console.log('[Toast] ' + msg); },
        toastError: function(msg) { console.error('[Toast Error] ' + msg); }
    };

    // XPTV uses textual response bodies and post(url, body, options).
    function __xptv_request(method, url, body, options) {
        if (typeof url !== 'string' || !/^https?:[/][/]/i.test(url.trim())) {
            throw new Error('XPTV 请求缺少有效的 HTTP 地址；请检查分类 ext.url 和源站返回内容');
        }
        options = Object.assign({}, options || {}, { method: method });
        if (body !== undefined) options.data = body;
        var res = req(url, options);
        if (res.error || res.code < 200 || res.code >= 400) {
            throw new Error(method + ' ' + url + ': ' + (res.error || ('HTTP ' + res.code)));
        }
        return { status: res.code, statusCode: res.code, headers: res.headers || {}, data: res.content || '' };
    }
    var $fetch = {
        get: function(url, options) { return __xptv_request('GET', url, undefined, options); },
        post: function(url, body, options) { return __xptv_request('POST', url, body, options); },
        put: function(url, body, options) { return __xptv_request('PUT', url, body, options); },
        delete: function(url, options) { return __xptv_request('DELETE', url, undefined, options); }
    };

    var $html = {
        elements: function(html, selector) {
            return pdfa(html, selector);
        },
        text: function(html, selector) {
            if (!selector) return pdfh(html, 'Text');
            return pdfh(html, selector + '&&Text');
        },
        attr: function(html, selector, attrName) {
            if (!attrName) return pdfh(html, '&&' + selector);
            return pdfh(html, selector + '&&' + attrName);
        }
    };

    // 相对 URL 补全
    function urljoin(base, rel) {
        if (!rel) return '';
        if (rel.indexOf('http://') === 0 || rel.indexOf('https://') === 0 || rel.indexOf('//') === 0) {
            if (rel.indexOf('//') === 0) return 'https:' + rel;
            return rel;
        }
        if (!base) return rel;
        var m = base.match(/^(https?:\\/\\/[^\\/]+)/i);
        var host = m ? m[1] : '';
        if (rel.indexOf('/') === 0) {
            return host + rel;
        }
        var path = base.replace(/\\?.*$/, '');
        var lastSlash = path.lastIndexOf('/');
        if (lastSlash > 8) {
            path = path.substring(0, lastSlash + 1);
        } else {
            path = path + '/';
        }
        return path + rel;
    }

    // pdfa / pdfh 由随应用打包的 SpiderDOM.js 提供。
    function pd(html, rule, baseUrl) {
        var val = pdfh(html, rule);
        return urljoin(baseUrl, val);
    }
    """
    
    /// 包装通用 Spider 执行器的 JS 代码
    static let runnerJS: String = """
    function __is_xptv() {
        return typeof getConfig === 'function' || typeof getCards === 'function';
    }

    async function __spider_init(ext) {
        if (__is_xptv()) {
            if (typeof init === 'function') {
                await init(ext);
            }
            return JSON.stringify({ code: 0 });
        }
        if (typeof init === 'function') {
            try { await init(ext); } catch(e) { console.log('init error: ' + e); }
        } else if (typeof rule !== 'undefined' && typeof rule.init === 'function') {
            try { await rule.init(ext); } catch(e) { console.log('rule.init error: ' + e); }
        }
        return JSON.stringify({ code: 0 });
    }

    async function __spider_home(filter) {
        if (__is_xptv()) {
            try {
                var cfg = (typeof getConfig === 'function') ? argsify(await getConfig()) : {};
                var classes = [];
                var tabs = Array.isArray(cfg.tabs) ? cfg.tabs : (Array.isArray(cfg.class) ? cfg.class : []);
                for (var i = 0; i < tabs.length; i++) {
                    var t = tabs[i];
                    if (!t || typeof t !== 'object') continue;
                    var name = t.name || t.type_name;
                    if (!name) continue;
                    // Keep the entire extension (URL, ordering, time filters), not just its id.
                    var tabExt = t.ext !== undefined && t.ext !== null ? t.ext : t.type_id;
                    if (tabExt === undefined || tabExt === null) tabExt = {};
                    classes.push({
                        type_id: JSON.stringify({ __xptv_tab: true, ext: tabExt, index: i }),
                        type_name: String(name)
                    });
                }
                var list = [];
                var homeError = null;
                if (typeof getCards === 'function' && classes.length) {
                    try {
                        var firstExt = JSON.parse(classes[0].type_id).ext;
                        var cardsRes = argsify(await getCards(jsonify(firstExt)));
                        if (cardsRes && cardsRes.list && Array.isArray(cardsRes.list)) {
                            for (var j = 0; j < cardsRes.list.length; j++) {
                                var item = cardsRes.list[j];
                                var vid = (typeof item.ext === 'object') ? JSON.stringify(item.ext) : String(item.ext || item.vod_id || item.id || '');
                                list.push({
                                    vod_id: vid,
                                    vod_name: item.vod_name || item.title || '',
                                    vod_pic: item.vod_pic || item.cover || '',
                                    vod_remarks: item.vod_remarks || item.subTitle || item.remarks || ''
                                });
                            }
                        }
                    } catch (error) {
                        homeError = '首页推荐加载失败：' + __spider_errorMessage(error);
                    }
                }
                if (!classes.length) {
                    throw new Error('XPTV 未返回可用分类；源站可能返回空页面或页面结构已变化，请检查 getConfig().tabs / class');
                }
                return JSON.stringify({ class: classes, list: list, homeError: homeError });
            } catch(e) {
                console.log('xptv home error: ' + e);
                throw e;
            }
        }
        if (typeof home === 'function') {
            return await home(filter);
        }
        if (typeof rule !== 'undefined') {
            if (typeof rule.home === 'function') {
                return await rule.home(filter);
            }
            var classes = [];
            if (rule.class_name && rule.class_url) {
                var names = rule.class_name.split('&');
                var urls = rule.class_url.split('&');
                for (var i = 0; i < Math.min(names.length, urls.length); i++) {
                    classes.push({
                        type_id: urls[i].trim(),
                        type_name: names[i].trim()
                    });
                }
            }
            var result = { class: classes, list: [] };
            if (typeof __spider_homeVod === 'function') {
                try {
                    var vodRes = JSON.parse(await __spider_homeVod());
                    if (vodRes && vodRes.list) {
                        result.list = vodRes.list;
                    }
                } catch(e) {}
            }
            return JSON.stringify(result);
        }
        return JSON.stringify({ class: [], list: [] });
    }

    async function __spider_homeVod() {
        if (typeof homeVod === 'function') {
            return await homeVod();
        }
        if (typeof rule !== 'undefined') {
            if (typeof rule.homeVod === 'function') {
                return await rule.homeVod();
            }
            var list = [];
            var recRule = rule['推荐'] || rule['一级'];
            if (recRule && rule.host) {
                try {
                    var html = req(rule.host).content || '';
                    var parts = recRule.split(';');
                    if (parts.length >= 4) {
                        var items = pdfa(html, parts[0]);
                        for (var i = 0; i < items.length; i++) {
                            var item = items[i];
                            var name = pdfh(item, parts[2]);
                            var id = pd(item, parts[3], rule.host);
                            var pic = parts.length > 4 ? pd(item, parts[4], rule.host) : '';
                            var note = parts.length > 5 ? pdfh(item, parts[5]) : '';
                            if (name && id) {
                                list.push({
                                    vod_id: id,
                                    vod_name: name,
                                    vod_pic: pic,
                                    vod_remarks: note
                                });
                            }
                        }
                    }
                } catch(e) {
                    console.log('homeVod error: ' + e);
                }
            }
            return JSON.stringify({ list: list });
        }
        return JSON.stringify({ list: [] });
    }

    async function __spider_category(tid, pg, filter, extendJson) {
        if (__is_xptv()) {
            try {
                var tab = argsify(tid);
                var ext = tab && tab.__xptv_tab === true ? tab.ext : tab;
                if (typeof ext === 'string') {
                    try { ext = JSON.parse(ext); } catch (_) { ext = { id: ext }; }
                }
                if (!ext || typeof ext !== 'object' || Array.isArray(ext)) ext = { id: ext == null ? tid : ext };
                ext = Object.assign({}, ext);
                ext.page = parseInt(pg) || 1;
                ext.filters = Object.assign({}, ext.filters || {}, argsify(extendJson));
                var cardsRes = (typeof getCards === 'function') ? argsify(await getCards(jsonify(ext))) : {};
                var list = [];
                if (cardsRes && cardsRes.list && Array.isArray(cardsRes.list)) {
                    for (var j = 0; j < cardsRes.list.length; j++) {
                        var item = cardsRes.list[j];
                        var vid = (typeof item.ext === 'object') ? JSON.stringify(item.ext) : String(item.ext || item.vod_id || item.id || '');
                        list.push({
                            vod_id: vid,
                            vod_name: item.vod_name || item.title || '',
                            vod_pic: item.vod_pic || item.cover || '',
                            vod_remarks: item.vod_remarks || item.subTitle || item.remarks || ''
                        });
                    }
                }
                return JSON.stringify({ page: parseInt(pg), pagecount: 999, limit: list.length, total: 999, list: list });
            } catch(e) {
                console.log('xptv category error: ' + e);
                throw e;
            }
        }
        var extObj = {};
        try { if (extendJson) extObj = JSON.parse(extendJson); } catch(e) {}
        
        if (typeof category === 'function') {
            return await category(tid, pg, filter, extObj);
        }
        if (typeof rule !== 'undefined') {
            if (typeof rule.category === 'function') {
                return await rule.category(tid, pg, filter, extObj);
            }
            var list = [];
            if (rule.host && rule.url && rule['一级']) {
                try {
                    var targetUrl = rule.host + rule.url.replace('fyclass', tid).replace('fypage', pg);
                    var html = req(targetUrl).content || '';
                    var parts = rule['一级'].split(';');
                    if (parts.length >= 4) {
                        var items = pdfa(html, parts[0]);
                        for (var i = 0; i < items.length; i++) {
                            var item = items[i];
                            var name = pdfh(item, parts[2]);
                            var id = pd(item, parts[3], rule.host);
                            var pic = parts.length > 4 ? pd(item, parts[4], rule.host) : '';
                            var note = parts.length > 5 ? pdfh(item, parts[5]) : '';
                            if (name && id) {
                                list.push({
                                    vod_id: id,
                                    vod_name: name,
                                    vod_pic: pic,
                                    vod_remarks: note
                                });
                            }
                        }
                    }
                } catch(e) {
                    console.log('category error: ' + e);
                }
            }
            return JSON.stringify({ page: parseInt(pg), pagecount: 999, limit: list.length, total: 999, list: list });
        }
        return JSON.stringify({ list: [] });
    }

    async function __spider_detail(id) {
        if (__is_xptv()) {
            try {
                var ext = argsify(id);
                var tracksRes = (typeof getTracks === 'function') ? argsify(await getTracks(jsonify(ext))) : {};
                var lines = [];
                var playUrls = [];
                if (tracksRes && tracksRes.list && Array.isArray(tracksRes.list)) {
                    for (var i = 0; i < tracksRes.list.length; i++) {
                        var line = tracksRes.list[i];
                        lines.push(line.title || ('线路 ' + (i + 1)));
                        var epList = [];
                        var tracks = line.tracks || [];
                        for (var j = 0; j < tracks.length; j++) {
                            var ep = tracks[j];
                            var epName = ep.name || ('第' + (j + 1) + '集');
                            var epExt = (typeof ep.ext === 'object') ? JSON.stringify(ep.ext) : String(ep.ext || ep.url || '');
                            epList.push(epName + '$' + epExt);
                        }
                        playUrls.push(epList.join('#'));
                    }
                }
                if (lines.length === 0) {
                    lines.push('默认线路');
                    playUrls.push('正片$' + id);
                }
                var video = {
                    vod_id: id,
                    vod_name: (ext.title || ext.name || '剧集详情'),
                    vod_pic: (ext.pic || ext.cover || ''),
                    vod_remarks: '',
                    vod_content: '',
                    vod_play_from: lines.join('$$$'),
                    vod_play_url: playUrls.join('$$$')
                };
                return JSON.stringify({ list: [video] });
            } catch(e) {
                console.log('xptv detail error: ' + e);
                throw e;
            }
        }
        if (typeof detail === 'function') {
            return await detail(id);
        }
        if (typeof rule !== 'undefined') {
            if (typeof rule.detail === 'function') {
                return await rule.detail(id);
            }
            var targetUrl = (id.indexOf('http') === 0) ? id : (rule.host + id);
            try {
                var html = req(targetUrl).content || '';
                var dRule = rule['二级'] || {};
                var title = dRule.title ? pdfh(html, dRule.title) : '';
                var pic = dRule.img ? pd(html, dRule.img, rule.host) : '';
                var desc = dRule.desc ? pdfh(html, dRule.desc) : '';
                var content = dRule.content ? pdfh(html, dRule.content) : '';
                
                var tabs = [];
                if (dRule.tabs) {
                    var tabItems = pdfa(html, dRule.tabs);
                    for (var t = 0; t < tabItems.length; t++) {
                        tabs.push(pdfh(tabItems[t], 'Text') || ('线路 ' + (t + 1)));
                    }
                }
                if (tabs.length === 0) tabs.push('播放线路');
                
                var playUrls = [];
                if (dRule.lists) {
                    var listRule = dRule.lists.replace(':eq(#id)', '');
                    var links = pdfa(html, listRule);
                    var epUrls = [];
                    for (var l = 0; l < links.length; l++) {
                        var epName = pdfh(links[l], 'Text') || ('第' + (l + 1) + '集');
                        var epLink = pd(links[l], 'a&&href', rule.host);
                        if (epLink) {
                            epUrls.push(epName + '$' + epLink);
                        }
                    }
                    playUrls.push(epUrls.join('#'));
                } else {
                    playUrls.push('正片$' + targetUrl);
                }
                
                var video = {
                    vod_id: id,
                    vod_name: title || '未知影片',
                    vod_pic: pic,
                    vod_remarks: desc,
                    vod_content: content,
                    vod_play_from: tabs.join('$$$'),
                    vod_play_url: playUrls.join('$$$')
                };
                return JSON.stringify({ list: [video] });
            } catch(e) {
                console.log('detail error: ' + e);
            }
        }
        return JSON.stringify({ list: [] });
    }

    async function __spider_search(wd, quick, pg) {
        if (__is_xptv()) {
            try {
                var searchRes = (typeof search === 'function') ? argsify(await search(jsonify({ text: wd, wd: wd, page: parseInt(pg) || 1 }))) : {};
                var list = [];
                if (searchRes && searchRes.list && Array.isArray(searchRes.list)) {
                    for (var j = 0; j < searchRes.list.length; j++) {
                        var item = searchRes.list[j];
                        var vid = (typeof item.ext === 'object') ? JSON.stringify(item.ext) : String(item.ext || item.vod_id || item.id || '');
                        list.push({
                            vod_id: vid,
                            vod_name: item.vod_name || item.title || '',
                            vod_pic: item.vod_pic || item.cover || '',
                            vod_remarks: item.vod_remarks || item.subTitle || item.remarks || ''
                        });
                    }
                }
                return JSON.stringify({ list: list });
            } catch(e) {
                console.log('xptv search error: ' + e);
                throw e;
            }
        }
        if (typeof search === 'function') {
            return await search(wd, quick, pg);
        }
        if (typeof rule !== 'undefined') {
            if (typeof rule.search === 'function') {
                return await rule.search(wd, quick, pg);
            }
            var list = [];
            if (rule.host && rule.searchUrl && rule['搜索']) {
                try {
                    var targetUrl = rule.host + rule.searchUrl.replace('**', encodeURIComponent(wd)).replace('fypage', pg);
                    var html = req(targetUrl).content || '';
                    var parts = rule['搜索'].split(';');
                    if (parts.length >= 4) {
                        var items = pdfa(html, parts[0]);
                        for (var i = 0; i < items.length; i++) {
                            var item = items[i];
                            var name = pdfh(item, parts[2]);
                            var id = pd(item, parts[3], rule.host);
                            var pic = parts.length > 4 ? pd(item, parts[4], rule.host) : '';
                            var note = parts.length > 5 ? pdfh(item, parts[5]) : '';
                            if (name && id) {
                                list.push({
                                    vod_id: id,
                                    vod_name: name,
                                    vod_pic: pic,
                                    vod_remarks: note
                                });
                            }
                        }
                    }
                } catch(e) {
                    console.log('search error: ' + e);
                }
            }
            return JSON.stringify({ list: list });
        }
        return JSON.stringify({ list: [] });
    }

    async function __spider_play(flag, id, flagsJson) {
        if (__is_xptv()) {
            try {
                if (typeof getPlayinfo === 'function') {
                    var ext = argsify(id);
                    var playRes = argsify(await getPlayinfo(jsonify(ext)));
                    if (playRes && playRes.urls && playRes.urls.length > 0) {
                        var header = (playRes.headers && playRes.headers.length > 0) ? playRes.headers[0] : {};
                        return JSON.stringify({ parse: 0, url: playRes.urls[0], header: header });
                    }
                }
            } catch(e) {
                console.log('xptv play error: ' + e);
                throw e;
            }
        }
        var flags = [];
        try { if (flagsJson) flags = JSON.parse(flagsJson); } catch(e) {}
        if (typeof play === 'function') {
            return await play(flag, id, flags);
        }
        if (typeof rule !== 'undefined' && typeof rule.play === 'function') {
            return await rule.play(flag, id, flags);
        }
        return JSON.stringify({ parse: 0, url: id });
    }
    """
}
