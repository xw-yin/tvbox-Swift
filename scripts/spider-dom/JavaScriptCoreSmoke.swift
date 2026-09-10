import Foundation
import JavaScriptCore

/// Runs against Apple's engine in CI, including the exact app Promise bridge.
@main
struct JavaScriptCoreSmoke {
    static func main() throws {
        let context = JSContext()!
        let log: @convention(block) (String) -> Void = { _ in }
        let request: @convention(block) (String, String) -> String = { _, _ in
            return #"{"code":200,"content":"{\"title\":\"Native Promise\"}","headers":{}}"#
        }
        context.setObject(log, forKeyedSubscript: "__native_log" as NSString)
        context.setObject(request, forKeyedSubscript: "__native_request" as NSString)
        context.exceptionHandler = { context, exception in context?.exception = exception }
        let dom = try String(contentsOfFile: "tvbox/Services/Spider/SpiderDOM.js", encoding: .utf8)
        let sampleSpider = """
        var rule = {
            title: '测试源',
            host: 'https://fixture.invalid',
            home: function(filter) {
                var cheerio = createCheerio();
                var $ = cheerio.load('<div class="item"><h2>测试电影</h2></div>');
                var title = $('h2').text();
                return JSON.stringify({
                    class: [{ type_id: '1', type_name: '电影' }],
                    list: [{ vod_id: '1', vod_name: title, vod_pic: '', vod_remarks: '' }]
                });
            },
            homeVod: function() {
                return JSON.stringify({ list: [] });
            },
            category: function(tid, pg, filter, extend) {
                return JSON.stringify({ page: 1, pagecount: 1, limit: 10, total: 10, list: [] });
            },
            detail: function(id) {
                return JSON.stringify({ list: [{ vod_id: id, vod_name: '测试详情' }] });
            },
            search: function(wd, quick, pg) {
                return JSON.stringify({ list: [] });
            },
            play: function(flag, id, flags) {
                return JSON.stringify({ parse: 0, url: id });
            }
        };
        """
        for source in [dom, DrpyRuntime.coreJS, sampleSpider, DrpyRuntime.runnerJS] {
            context.evaluateScript(source)
            precondition(context.exception == nil, context.exception?.toString() ?? "JS exception")
        }
        context.setObject("__spider_home", forKeyedSubscript: "__spider_method" as NSString)
        context.setObject([false], forKeyedSubscript: "__spider_arguments" as NSString)
        context.evaluateScript(DrpyRuntime.callJS)
        let deadline = Date().addingTimeInterval(5)
        while context.objectForKeyedSubscript("__spider_completion")?.forProperty("done")?.toBool() != true {
            precondition(Date() < deadline, "JavaScriptCore Promise settlement timed out")
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            context.evaluateScript("void 0")
        }
        let result = context.objectForKeyedSubscript("__spider_completion")!
        precondition(result.forProperty("error").isUndefined, result.toString())
        let json = result.forProperty("value").toString()!
        precondition(json.contains("测试电影"), json)
        print("Apple JavaScriptCore: Drpy Spider → Cheerio/CryptoJS → JSON passed")
    }
}
