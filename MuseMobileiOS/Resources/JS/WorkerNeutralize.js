        (function(){
            if(window.__splWorkerNeutralized) return;
            window.__splWorkerNeutralized = true;

            /* === Service Worker: unregister + prevent re-registration === */
            if(navigator.serviceWorker){
                try {
                    navigator.serviceWorker.register = function(){
                        return Promise.reject(new Error('SW blocked by MuseMobile'));
                    };
                } catch(e){}
                try {
                    navigator.serviceWorker.getRegistrations().then(function(regs){
                        regs.forEach(function(reg){
                            reg.unregister().then(function(ok){
                                if(ok){
                                    try{AndBridge.dbg('s','SW unregistered: '+reg.scope)}catch(e){}
                                }
                            }).catch(function(){});
                        });
                    }).catch(function(){});
                } catch(e){}
            }

            /* === Interval throttle: 250ms -> 500ms ===
               Gentle 2x throttle for burst polling timers.
               Core intervals (500ms progress, 1000ms Connect) 
               have different delays and pass through untouched.
               PowerSave modifies delay before this check fires,
               so no compounding occurs. */
            try {
                var origSI = window.setInterval.bind(window);
                window.setInterval = function(fn, delay){
                    if(delay === 250) delay = 500;
                    return origSI(fn, delay);
                };
            } catch(e){}
        })();
    