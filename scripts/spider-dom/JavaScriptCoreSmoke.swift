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
        for source in [dom, DrpyRuntime.coreJS, DrpyRuntime.runnerJS, """
        async function getConfig() { return JSON.stringify({tabs:[{name:'Movies',ext:{id:1}}]}); }
        async function getCards(ext) {
            if (JSON.parse(ext).id !== 1) throw new Error('Argument contract');
            const values = await Promise.all([Promise.resolve('Native'), Promise.resolve('Promise')]);
            const response = await $fetch.get('https://fixture.invalid');
            const cheerio = createCheerio();
            const title = cheerio.load('<h2>' + values.join(' ') + '</h2>')('h2').text();
            if (JSON.parse(response.data).title !== title) throw new Error('Response contract');
            if (createCryptoJS().MD5('abc').toString() !== '900150983cd24fb0d6963f7d28e17f72') throw new Error('Crypto');
            if (typeof loadJSEncrypt() !== 'function') throw new Error('RSA factory');
            return JSON.stringify({list:[{title:title, ext:{id:1}}]});
        }
        """] {
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
        precondition(json.contains("Native Promise"), json)
        let message = context.evaluateScript("__spider_errorMessage(Object.assign(new Error('HTTP 503'), {stack:'getCards@'}))")!.toString()!
        precondition(message.contains("HTTP 503") && message.contains("getCards@"), message)
        let classification = context.evaluateScript("""
        async function getCards() { throw new Error('HTTP 403'); }
        __spider_method = '__spider_home';
        __spider_arguments = [false];
        """)
        _ = classification
        context.evaluateScript(DrpyRuntime.callJS)
        let secondDeadline = Date().addingTimeInterval(5)
        while context.objectForKeyedSubscript("__spider_completion")?.forProperty("done")?.toBool() != true {
            precondition(Date() < secondDeadline)
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            context.evaluateScript("void 0")
        }
        let failedHome = context.objectForKeyedSubscript("__spider_completion")!.forProperty("value")!.toString()!
        let failedJSON = try JSONSerialization.jsonObject(with: Data(failedHome.utf8)) as! [String: Any]
        precondition((failedJSON["class"] as? [[String: Any]])?.count == 1)
        precondition((failedJSON["homeError"] as? String)?.contains("HTTP 403") == true)
        print("Apple JavaScriptCore: async XPTV → HTTP → Cheerio/CryptoJS → JSON passed")
    }
}
