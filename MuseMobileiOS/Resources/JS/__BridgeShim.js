// AndBridge shim — installed as a WKUserScript at document start so page JS
// can call window.AndBridge.* synchronously-looking. Every method posts to
// the single "AndBridge" WKScriptMessageHandler as {method, args}.
// Mirrors Android's @JavascriptInterface surface under identical names.
(function(){
    if (window.AndBridge) return;
    var METHODS = ["loginDetected","deferMessage","isWoke","wakeUp","wakeOff",
        "cssInjected","dbg","recAdContentIds","playLoaded","recMediaPosition",
        "recMediaStatus","onMediaItemsLoaded","onSearchCompleted","recAccountName",
        "openTimerDialog","enterPip","enterPipVideo","downloadTrack",
        "downloadCollection","skipDownload","cancelDownload","manageTShut",
        "manageTSleep","nFetch"];
    function post(method, args){
        try{
            window.webkit.messageHandlers.AndBridge.postMessage({method: method, args: args || []});
        }catch(e){}
    }
    var bridge = {};
    METHODS.forEach(function(m){
        if (m === "nFetch") {
            // Synchronous-looking fetch used by ClassicBridge/AndroidAuto:
            // implemented via a native-backed async shim (mngFetch pattern).
            bridge[m] = function(url, opts){
                var id = "n" + Math.random().toString(36).slice(2);
                var p = new Promise(function(res){
                    window.__splNFetchResolvers = window.__splNFetchResolvers || {};
                    window.__splNFetchResolvers[id] = res;
                    post("nFetch", [url, (typeof opts === "string" ? opts : JSON.stringify(opts||{})), id]);
                });
                // ClassicBridge expects a JSON string synchronously; where the
                // page uses async callers (AndroidAuto GraphQL) the promise form
                // is used via window.mngFetch instead. Keep both:
                return p;
            };
        } else if (m === "isWoke") {
            bridge[m] = function(){ return true; };
        } else {
            bridge[m] = (function(method){
                return function(){
                    var a = Array.prototype.slice.call(arguments);
                    post(method, a);
                };
            })(m);
        }
    });
    // Legacy alias used by shouldInterceptRequest toasts:
    window.AndBridge = bridge;
    // mngFetch: promise-based native fetch (normal mode leans into this on iOS
    // since WKWebView ignores per-view proxies). Returns a Response-like
    // identical in shape to ClassicBridge: {status, ok, headers, url,
    // text()/json()/arrayBuffer()/clone()}. Early-bootstrap callers
    // (FetchOverride pre-playerScript, AdStateHook res.clone()) rely on it.
    // window.AndBridge.nFetch promise form above is unchanged (ClassicBridge
    // awaits the raw native {status,body,headers} JSON string directly).
    window.mngFetch = function(url, opts){
        var inputUrl = (typeof url === "string") ? url : ((url && url.url) || String(url));
        var o = opts || {};
        var h = o.headers || {};
        var headers = {};
        try {
            if (typeof h.forEach === "function") { h.forEach(function(v, k){ headers[k] = v; }); }
            else if (typeof h.get === "function") {
                try {
                    headers["Authorization"] = h.get("Authorization");
                    headers["Client-Token"] = h.get("Client-Token");
                    headers["Content-Type"] = h.get("Content-Type");
                } catch(e){}
            } else { headers = h; }
        } catch(e){ headers = {}; }
        var body = null;
        if (o.body) { body = (typeof o.body === "string") ? o.body : JSON.stringify(o.body); }
        var payload = JSON.stringify({ method: o.method || "GET", headers: headers, body: body });
        return bridge.nFetch(inputUrl, payload).then(function(raw){
            var data;
            try { data = (typeof raw === "string") ? JSON.parse(raw) : raw; }
            catch(e){ throw new Error("Bad native response: " + raw); }
            if (!data || data.status === 0) { throw new Error("network error: " + (data ? data.body : "unknown")); }
            function makeRes(d){
                return {
                    status: d.status,
                    ok: d.status >= 200 && d.status < 300,
                    headers: new Headers(d.headers || {}),
                    url: inputUrl,
                    json: function(){ return Promise.resolve(JSON.parse(d.body || "{}")); },
                    text: function(){ return Promise.resolve(d.body || ""); },
                    arrayBuffer: function(){ return Promise.resolve(new TextEncoder().encode(d.body || "").buffer); },
                    clone: function(){ return makeRes(d); }
                };
            }
            return makeRes(data);
        });
    };
})();
