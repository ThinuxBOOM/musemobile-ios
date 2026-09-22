        (function(){
            if (window.__splAdblockify) return;
            window.__splAdblockify = 1;
            var lastSkipAt = 0;

            var AD_EMPTY_SUBS = [
                'adeventtracker.spotify.com',
                'pixel.spotify.com',
                'pixel-static.spotify.com',
                'adstudio.spotify.com',
                'ads.spotify.com',
                'audio-ads.spotify.com',
                'ads-akp.spotify.com',
                'ads-fa.spotify.com',
                '/vast/',
                '/ad-logic/',
                'gabo-receiver-service/public/v3/events',
                'doubleclick.net',
                'googlesyndication.com',
                'amillionads.com',
                '2mdn.net',
                'adxcel.com',
                'adstudio-assets.scdn.co'
            ];
            var PATCH_SUBS = [
                'product_state',
                'product-state',
                'bootstrap',
                'remote_config',
                'remote-config',
                'exp-features',
                'connect-state',
                '/state',
                'pathfinder',
                'melody/v1/msg',
                'track-playback'
            ];

            function urlOf(input){
                try {
                    if (typeof input === 'string') return input;
                    if (input && input.url) return input.url;
                } catch(e){}
                return '';
            }
            function isAdOnlyUrl(u){
                if (!u || !u.indexOf) return false;
                for (var i = 0; i < AD_EMPTY_SUBS.length; i++) {
                    if (u.indexOf(AD_EMPTY_SUBS[i]) !== -1) return true;
                }
                return false;
            }
            function shouldPatchUrl(u){
                if (!u || !u.indexOf) return false;
                for (var j = 0; j < PATCH_SUBS.length; j++) {
                    if (u.indexOf(PATCH_SUBS[j]) !== -1) return true;
                }
                return false;
            }
            function emptyAdResponse(){
                try {
                    return new Response(JSON.stringify({ slots: [], adSlots: [], creatives: [], cards: [], items: [] }), {
                        status: 200, statusText: 'OK', headers: { 'Content-Type': 'application/json' }
                    });
                } catch(e){ return null; }
            }

            function patchValueForKey(k, v){
                if (k === 'ads') {
                    if (typeof v === 'string') return '0';
                    if (typeof v === 'boolean') return false;
                    if (typeof v === 'number') return 0;
                    return '0';
                }
                if (k === 'catalogue' || k === 'product' || k === 'type') return 'premium';
                if (k === 'player-license' || k === 'player-license-v2') return 'premium';
                if (k === 'on-demand' || k === 'on_demand' || k === 'onDemand') return true;
                if (k === 'streaming') return true;
                if (k === 'shuffle') return false;
                if (k === 'pick-and-shuffle' || k === 'pick_and_shuffle') return false;
                if (k === 'enableEsperantoMigration') return true;
                if (k === 'enableInAppMessaging') return false;
                if (k === 'hideUpgradeCTA') return true;
                if (k === 'enablePremiumUserForMiniPlayer') return true;
                if (k === 'isNewAdsNpvEnabled') return false;
                if (k === 'enableInAppMessaging') return false;
                return v;
            }
            var PATCH_KEYS = {
                'ads': 1, 'catalogue': 1, 'product': 1, 'type': 1,
                'player-license': 1, 'player-license-v2': 1,
                'on-demand': 1, 'on_demand': 1, 'onDemand': 1,
                'streaming': 1, 'shuffle': 1,
                'pick-and-shuffle': 1, 'pick_and_shuffle': 1,
                'enableEsperantoMigration': 1, 'enableInAppMessaging': 1,
                'hideUpgradeCTA': 1, 'enablePremiumUserForMiniPlayer': 1,
                'isNewAdsNpvEnabled': 1
            };
            function patchObjDeep(o, depth){
                var changed = false;
                if (!o || typeof o !== 'object' || depth > 6) return false;
                if (o instanceof Array) {
                    for (var i = 0; i < o.length; i++) {
                        if (patchObjDeep(o[i], depth + 1)) changed = true;
                    }
                    return changed;
                }
                var keys = null;
                try { keys = Object.keys(o); } catch(e){ return false; }
                for (var k = 0; k < keys.length; k++) {
                    var key = keys[k];
                    var val;
                    try { val = o[key]; } catch(e){ continue; }
                    if (PATCH_KEYS[key] === 1 && (typeof val === 'string' || typeof val === 'boolean' || typeof val === 'number')) {
                        var nv = patchValueForKey(key, val);
                        if (nv !== val) { try { o[key] = nv; changed = true; } catch(e){} }
                    } else if (key === 'pairs' && val && typeof val === 'object') {
                        if (patchObjDeep(val, depth + 1)) changed = true;
                    } else if (val && typeof val === 'object') {
                        if (patchObjDeep(val, depth + 1)) changed = true;
                    }
                    if (key === 'adSlotEvent' || key === 'adSlots' || key === 'slots') {
                        try {
                            if (o[key] instanceof Array && o[key].length > 0) {
                                var keep = [];
                                for (var s = 0; s < o[key].length; s++) {
                                    var slot = o[key][s];
                                    var sid = slot && (slot.slotId || slot.slot_id || slot.id || '');
                                    if (typeof sid === 'string' && (sid.indexOf('stream') !== -1 || sid.indexOf('preroll') !== -1 || sid.indexOf('midroll') !== -1 || sid.indexOf('marquee') !== -1 || sid.indexOf('home-above') !== -1 || sid.indexOf('sponsored') !== -1)) {
                                        changed = true;
                                        continue;
                                    }
                                    keep.push(slot);
                                }
                                if (keep.length !== o[key].length) { o[key] = keep; changed = true; }
                            }
                        } catch(e){}
                    }
                }
                return changed;
            }

            function applyExpFeatures(){
                var names = ['spicetify-exp-features', 'spotify-exp-features', 'exp-features'];
                for (var n = 0; n < names.length; n++) {
                    try {
                        var raw = null;
                        try { raw = localStorage.getItem(names[n]); } catch(e){}
                        var obj = {};
                        if (raw) { try { obj = JSON.parse(raw) || {}; } catch(e){ obj = {}; } }
                        var touched = false;
                        function ensure(k, v){
                            if (!obj[k] || typeof obj[k] !== 'object') obj[k] = {};
                            if (obj[k].value !== v) { obj[k].value = v; touched = true; }
                        }
                        ensure('enableEsperantoMigration', true);
                        ensure('enableInAppMessaging', false);
                        ensure('hideUpgradeCTA', true);
                        ensure('enablePremiumUserForMiniPlayer', true);
                        if (touched) {
                            try { localStorage.setItem(names[n], JSON.stringify(obj)); } catch(e){}
                        }
                    } catch(e){}
                }
            }

            function applyCss(){
                try {
                    if (document.getElementById('spl-adblockify-style')) return;
                    var st = document.createElement('style');
                    st.id = 'spl-adblockify-style';
                    st.textContent = '[data-testid*="home-ad-"],[data-testid="home-ad-card"],[data-testid="home-ads-container"],[data-testid*="hpto"],#leaderboard-ad-element,#view-billboard-ad,[data-testid="billboard-minimized"],[data-testid="billboard-image-link"],[data-testid="hpto-parent-container"],[data-testid="hpto-native"],[data-testid="hpto-image"],[data-testid="html-hpto-container"],[data-testid="html-hpto-iframe"],[data-testid="hpto-native-buttons"],.main-leaderboardComponent-container,.sponsor-container,.main-topBar-UpgradeButton,[data-testid="signup-bar"],a[href^="https://www.spotify.com/premium/"],button[aria-label="Upgrade"],[data-testid*="upsell"],[data-testid*="upgrade"],[data-testid*="billboard"],div[data-encore-id="banner"]{display:none!important}.main-home-homeHeader{height:256px!important}';
                    var t = document.head || document.documentElement;
                    if (t) t.appendChild(st);
                } catch(e){}
            }

            function tryDisableManagers(){
                try {
                    var mgr = null;
                    try { mgr = window.Spotify && window.Spotify.Platform && window.Spotify.Platform.AdManagers; } catch(e){}
                    if (!mgr) { try { mgr = window.Spicetify && window.Spicetify.Platform && window.Spicetify.Platform.AdManagers; } catch(e2){} }
                    if (!mgr || typeof mgr !== 'object') return;
                    var names = ['audio', 'billboard', 'leaderboard', 'sponsoredPlaylist', 'inStream', 'inStreamApi', 'vto', 'embedded', 'embeddedAd'];
                    for (var i = 0; i < names.length; i++) {
                        try {
                            var m = mgr[names[i]];
                            if (m && typeof m.disable === 'function') { try { m.disable(); } catch(e){} }
                            if (m && typeof m.disableLeaderboard === 'function') { try { m.disableLeaderboard(); } catch(e){} }
                            if (m && m.manager && typeof m.manager.disable === 'function') { try { m.manager.disable(); } catch(e){} }
                            if (m) { try { m.isNewAdsNpvEnabled = false; } catch(e){} }
                        } catch(e){}
                    }
                    try { if (mgr.audio) mgr.audio.isNewAdsNpvEnabled = false; } catch(e){}
                } catch(e){}
            }
            function tryWebpackTheft(){
                try {
                    var queue = null;
                    var cands = ['webpackChunkopen', 'webpackChunkclient_web', 'rspackChunk', 'rspackChunkclient_web', 'webpackChunkspotify'];
                    for (var i = 0; i < cands.length; i++) {
                        try { if (window[cands[i]] && window[cands[i]].push) { queue = window[cands[i]]; break; } } catch(e){}
                    }
                    if (!queue) {
                        try {
                            var ks = Object.keys(window);
                            for (var k = 0; k < ks.length; k++) {
                                var kk = ks[k];
                                if (kk.indexOf('Chunk') !== -1) {
                                    try { if (window[kk] && window[kk].push) { queue = window[kk]; break; } } catch(e){}
                                }
                            }
                        } catch(e){}
                    }
                    if (!queue) return;
                    var dummy = null;
                    try { dummy = queue.push([[Date.now()], {}, function(r){ return r; }]); } catch(e){ return; }
                    if (!dummy) return;
                    try {
                        var mods = Object.keys(dummy.m || {});
                        for (var m = 0; m < mods.length; m++) {
                            var mod = null;
                            try { mod = dummy(mods[m]); } catch(e){ continue; }
                            if (!mod || typeof mod !== 'object') continue;
                            try {
                                var vals = Object.keys(mod);
                                for (var v = 0; v < vals.length; v++) {
                                    var fn = null;
                                    try { fn = mod[vals[v]]; } catch(e){ continue; }
                                    if (fn && (fn.SERVICE_ID === 'spotify.ads.esperanto.settings.proto.Settings' || fn.SERVICE_ID === 'spotify.ads.esperanto.proto.Settings')) {
                                        try { if (fn.settingsClient && fn.settingsClient.updateSlotEnabled) { } } catch(e){}
                                    }
                                }
                            } catch(e){}
                        }
                    } catch(e){}
                } catch(e){}
            }

            function isAdPlaying(){
                try {
                    var uri = window.splTrackUri || window.__curTrackUri || '';
                    if (uri && (uri.indexOf('spotify:ad:') === 0 || uri.indexOf('spotify:advertisement') === 0)) return true;
                } catch(e){}
                try {
                    var w = document.querySelector('[data-testid="now-playing-widget"]');
                    if (w) {
                        var t = (w.textContent || '').toLowerCase();
                        if (t.indexOf('advertisement') !== -1) return true;
                        var a = w.querySelector('a[href*="/ad/"],a[href*="advertisement"]');
                        if (a) return true;
                    }
                } catch(e){}
                try {
                    var tn = window.__curTrackName || '';
                    if (tn && tn.toLowerCase() === 'advertisement') return true;
                } catch(e){}
                return false;
            }
            function skipAd(){
                var now = Date.now();
                if (now - lastSkipAt < 2000) return;
                lastSkipAt = now;
                try { if (typeof window.actSkipForward === 'function') { window.actSkipForward(); } } catch(e){}
                try {
                    var fb = document.querySelector('button[data-testid="control-button-skip-forward"]');
                    if (fb) { try { fb.click(); } catch(e){} }
                } catch(e){}
                try { AndBridge.dbg('i', 'adblockify skip'); } catch(e){}
            }
            function adWatchdog(){
                try { if (isAdPlaying()) skipAd(); } catch(e){}
                try {
                    var vids = document.querySelectorAll('video');
                    for (var i = 0; i < vids.length; i++) {
                        try {
                            var v = vids[i];
                            var src = v.currentSrc || v.getAttribute('src') || '';
                            if (src && isAdOnlyUrl(src)) { try { v.muted = true; v.pause(); } catch(e){} }
                        } catch(e){}
                    }
                } catch(e){}
            }

            try {
                var prevFetch = window.fetch.bind(window);
                window.fetch = function(input, init){
                    var u = urlOf(input);
                    try {
                        if (u && isAdOnlyUrl(u)) {
                            var er = emptyAdResponse();
                            if (er) return Promise.resolve(er);
                        }
                    } catch(e){}
                    var p = null;
                    try { p = prevFetch(input, init); } catch(e){ return prevFetch.apply(this, arguments); }
                    try {
                        if (u && shouldPatchUrl(u)) {
                            return Promise.resolve(p).then(function(res){
                                try {
                                    if (!res || typeof res.clone !== 'function') return res;
                                    return res.clone().json().then(function(j){
                                        try {
                                            if (patchObjDeep(j, 0)) {
                                                return new Response(JSON.stringify(j), {
                                                    status: res.status, statusText: res.statusText,
                                                    headers: { 'Content-Type': 'application/json' }
                                                });
                                            }
                                        } catch(e){}
                                        return res;
                                    }).catch(function(){ return res; });
                                } catch(e){ return res; }
                            }).catch(function(){ return p; });
                        }
                    } catch(e){}
                    return p;
                };
            } catch(e){}

            try { applyCss(); } catch(e){}
            try { applyExpFeatures(); } catch(e){}
            try { tryDisableManagers(); } catch(e){}
            try { tryWebpackTheft(); } catch(e){}
            try { setTimeout(applyExpFeatures, 3000); } catch(e){}
            try {
                setInterval(function(){
                    try { if (window.__splBg) return; } catch(e){}
                    try { applyCss(); } catch(e){}
                    try { applyExpFeatures(); } catch(e){}
                    try { tryDisableManagers(); } catch(e){}
                    try { adWatchdog(); } catch(e){}
                }, 5000);
            } catch(e){}
            try {
                setInterval(function(){
                    try { if (window.__splBg) return; adWatchdog(); } catch(e){}
                }, 1000);
            } catch(e){}
            try {
                var mo = new MutationObserver(function(){ try { adWatchdog(); } catch(e){} });
                mo.observe(document.documentElement, { subtree: true, childList: true, attributes: true });
            } catch(e){}
            try { AndBridge.dbg('s', 'adblockify layer active'); } catch(e){}
        })();
    