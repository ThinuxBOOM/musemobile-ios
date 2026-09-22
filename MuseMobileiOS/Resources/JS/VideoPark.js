        (function(){
            if(window.__splVideoParkInit) return;
            window.__splVideoParkInit = true;

            try {
                var parked = [];

                function isCanvasVid(v){
                    try{
                        if(v.muted) return true;
                        if(v.hasAttribute && v.hasAttribute('loop')) return true;
                        if(v.style && v.style.objectFit === 'cover') return true;
                    }catch(e){}
                    return false;
                }

                function parkLive(){
                    var vs = document.querySelectorAll('video');
                    for(var i=0;i<vs.length;i++){
                        var v = vs[i];
                        if(v.__splParked) continue;
                        if(!isCanvasVid(v)) continue;
                        var src = v.currentSrc || v.getAttribute('src') || '';
                        /* blob: = MediaSource, can't be re-attached after load().
                           Leave those alone rather than strand them. */
                        if(!src || src.startsWith('blob:')) continue;
                        v.__splParked = true;
                        parked.push({el:v, src:src, t:(v.currentTime||0), playing:(!v.paused && !v.ended)});
                        try{ v.pause(); }catch(e){}
                        try{ v.removeAttribute('src'); }catch(e){}
                        try{ v.load(); }catch(e){}
                    }
                    return parked.length;
                }

                window.__splParkVideos = function(){
                    parkLive();
                };

                window.__splRestoreVideos = function(){
                    if(!parked.length) return;
                    for(var i=0;i<parked.length;i++){
                        var b = parked[i];
                        var v = b.el;
                        if(!v || !v.isConnected) continue;
                        /* Spotify already swapped in a fresh src (track changed
                           while backgrounded) - its own source wins. */
                        if(v.getAttribute('src') || v.currentSrc){ v.__splParked = false; continue; }
                        try{
                            v.src = b.src;
                            v.currentTime = b.t || 0;
                            if(b.playing){
                                var p = v.play();
                                if(p) p.catch(function(){});
                            }
                        }catch(e){}
                        v.__splParked = false;
                    }
                    parked.length = 0;
                    try{ AndBridge.dbg('s','videos restored from background park'); }catch(e){}
                };

                document.addEventListener('visibilitychange', function(){
                    if(document.visibilityState === 'hidden') window.__splParkVideos();
                    else window.__splRestoreVideos();
                });
            } catch(e){}
        })();
    