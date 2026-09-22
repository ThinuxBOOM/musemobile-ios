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
    // since WKWebView ignores per-view proxies).
    window.mngFetch = function(url, opts){
        return bridge.nFetch(url, opts).then(function(r){
            try { return typeof r === "string" ? JSON.parse(r) : r; }
            catch(e){ return r; }
        });
    };
})();
