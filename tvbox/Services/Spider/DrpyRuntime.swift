import Foundation

/// Drpy 与 CatVod 规范的 JavaScript 运行时支撑环境
struct DrpyRuntime {
    /// 注入到 JSContext 中的基础运行环境与 DOM 工具库
    static let coreJS: String = """
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

    // DOM 选择器微型实现 (基于正则表达式的高性能实现，兼容 Drpy pdfa / pdfh / pd 语法)
    function pdfa(html, rule) {
        if (!html || !rule) return [];
        var parts = rule.split(';');
        var selector = parts[0].trim();
        var tagMatch = selector.match(/^([a-zA-Z0-9_-]+)/);
        var classMatch = selector.match(/\\.([a-zA-Z0-9_-]+)/);
        var idMatch = selector.match(/#([a-zA-Z0-9_-]+)/);
        
        var tagName = tagMatch ? tagMatch[1] : '[a-zA-Z0-9_-]+';
        var regexStr = '<' + tagName + '\\\\b[^>]*';
        if (idMatch) {
            regexStr += '[^>]*id=[\"\\']' + idMatch[1] + '[\"\\']';
        }
        if (classMatch) {
            regexStr += '[^>]*class=[\"\\'][^\"\\']*\\\\b' + classMatch[1] + '\\\\b[^\"\\']*[\"\\']';
        }
        regexStr += '[^>]*>([\\\\s\\\\S]*?)<\\\\/' + (tagMatch ? tagMatch[1] : tagName) + '>';
        
        var re = new RegExp(regexStr, 'gi');
        var results = [];
        var match;
        while ((match = re.exec(html)) !== null) {
            results.push(match[0]);
        }
        return results;
    }

    function pdfh(html, rule) {
        if (!html || !rule) return '';
        var parts = rule.split('&&');
        var selector = parts[0].trim();
        var attr = parts.length > 1 ? parts[1].trim() : 'Text';

        var targetHtml = html;
        if (selector) {
            var items = pdfa(html, selector);
            if (items.length > 0) {
                targetHtml = items[0];
            }
        }

        if (attr === 'Text' || attr === 'text') {
            return targetHtml.replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').trim();
        } else if (attr === 'Html' || attr === 'html') {
            return targetHtml.trim();
        } else {
            var re = new RegExp(attr + '=[\\"\\\']([^\\"\\\']*)', 'i');
            var m = targetHtml.match(re);
            return m ? m[1].trim() : '';
        }
    }

    function pd(html, rule, baseUrl) {
        var val = pdfh(html, rule);
        return urljoin(baseUrl, val);
    }
    """
    
    /// 包装通用 Spider 执行器的 JS 代码
    static let runnerJS: String = """
    function __spider_init(ext) {
        if (typeof init === 'function') {
            try { init(ext); } catch(e) { console.log('init error: ' + e); }
        } else if (typeof rule !== 'undefined' && typeof rule.init === 'function') {
            try { rule.init(ext); } catch(e) { console.log('rule.init error: ' + e); }
        }
        return JSON.stringify({ code: 0 });
    }

    function __spider_home(filter) {
        if (typeof home === 'function') {
            return home(filter);
        }
        if (typeof rule !== 'undefined') {
            if (typeof rule.home === 'function') {
                return rule.home(filter);
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
                    var vodRes = JSON.parse(__spider_homeVod());
                    if (vodRes && vodRes.list) {
                        result.list = vodRes.list;
                    }
                } catch(e) {}
            }
            return JSON.stringify(result);
        }
        return JSON.stringify({ class: [], list: [] });
    }

    function __spider_homeVod() {
        if (typeof homeVod === 'function') {
            return homeVod();
        }
        if (typeof rule !== 'undefined') {
            if (typeof rule.homeVod === 'function') {
                return rule.homeVod();
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

    function __spider_category(tid, pg, filter, extendJson) {
        var extObj = {};
        try { if (extendJson) extObj = JSON.parse(extendJson); } catch(e) {}
        
        if (typeof category === 'function') {
            return category(tid, pg, filter, extObj);
        }
        if (typeof rule !== 'undefined') {
            if (typeof rule.category === 'function') {
                return rule.category(tid, pg, filter, extObj);
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

    function __spider_detail(id) {
        if (typeof detail === 'function') {
            return detail(id);
        }
        if (typeof rule !== 'undefined') {
            if (typeof rule.detail === 'function') {
                return rule.detail(id);
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

    function __spider_search(wd, quick, pg) {
        if (typeof search === 'function') {
            return search(wd, quick, pg);
        }
        if (typeof rule !== 'undefined') {
            if (typeof rule.search === 'function') {
                return rule.search(wd, quick, pg);
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

    function __spider_play(flag, id, flagsJson) {
        var flags = [];
        try { if (flagsJson) flags = JSON.parse(flagsJson); } catch(e) {}
        if (typeof play === 'function') {
            return play(flag, id, flags);
        }
        if (typeof rule !== 'undefined' && typeof rule.play === 'function') {
            return rule.play(flag, id, flags);
        }
        return JSON.stringify({ parse: 0, url: id });
    }
    """
}
