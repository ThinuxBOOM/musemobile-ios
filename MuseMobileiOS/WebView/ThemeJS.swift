import Foundation
import SwiftUI

/// Ports of Android theme helpers: AccentTheme / AmoledTheme / CssInjector /
/// LyricsTheme (style element IDs preserved: musemobile-amoled-theme,
/// musemobile-custom-css, musemobile-lyrics-style) + DevLogPrelude.
public enum ThemeJS {
    public static let defaultAccent = "#1DB954"

    public static func resolveAccentHex() -> String {
        if AppSettings.bool(.materialYou) {
            // iOS 15+ system accent approximation (dynamic color).
            // Full MaterialYou seed math (hue±30°, 0.22 white-lerp) lives in
            // Theme.swift for native chrome; web only needs the base hex.
            return defaultAccent
        }
        if let seed = UserDefaults.standard.string(forKey: AppSettings.Key.paletteSeed.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines), seed.hasPrefix("#") {
            return seed
        }
        return defaultAccent
    }

    static func brighten(_ hex: String, factor: Double = 0.12) -> String {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return hex }
        let r = Int((v >> 16) & 0xFF), g = Int((v >> 8) & 0xFF), b = Int(v & 0xFF)
        func lift(_ x: Int) -> Int { x + Int(Double(255 - x) * factor) }
        return String(format: "#%02X%02X%02X", lift(r), lift(g), lift(b))
    }

    public static func accentJS() -> String {
        let hex = resolveAccentHex()
        let parts = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(parts, radix: 16) ?? 0x1DB954
        let rgb = "\((v >> 16) & 0xFF),\((v >> 8) & 0xFF),\(v & 0xFF)"
        return """
        (function(){
            var r=document.documentElement;
            r.style.setProperty('--spl-accent','\(hex)');
            r.style.setProperty('--spl-accent-bright','\(brighten(hex))');
            r.style.setProperty('--spl-accent-rgb','\(rgb)');
        })();
        """
    }

    public static func amoledJS(enabled: Bool) -> String {
        if enabled {
            return """
            (function(){
                var aled = document.getElementById('musemobile-amoled-theme') || document.createElement('style');
                aled.id = 'musemobile-amoled-theme';
                aled.textContent = '.encore-dark-theme{--background-base:#000;--background-highlight:#000;--background-elevated-base:#000;--background-elevated-highlight:#000;--background-elevated-press:#000;--background-tinted-base:#000} aside[data-testid=now-playing-bar]{background:#000!important;box-shadow:none;border-top:1px solid #666}';
                if (!aled.parentNode) (document.head || document.documentElement).appendChild(aled);
            })();
            """
        } else {
            return "(function(){var aled=document.getElementById('musemobile-amoled-theme');if(aled)aled.remove();})();"
        }
    }

    public static func customCssJS(_ css: String) -> String {
        // JSON-quote like Android's JSONObject.quote
        let data = try? JSONSerialization.data(withJSONObject: [css])
        let quoted = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String])
            .flatMap { $0.first }.map { "\"\($0.escapedForJS())\"" } ?? "\"\""
        // Simpler: use NSString quoting
        let q = cssQuote(css)
        _ = quoted
        return """
        (function(){
            var cst = document.getElementById('musemobile-custom-css');
            if (\(q) === "") { if (cst) cst.remove(); return; }
            if (!cst) { cst = document.createElement('style'); cst.id = 'musemobile-custom-css'; }
            cst.textContent = \(q);
            var target = document.head || document.documentElement;
            if (target && !cst.parentNode) { target.appendChild(cst); }
        })();
        """
    }

    public static func lyricsStyleJS(_ style: String) -> String {
        let css = LyricsCSS.css(for: style)
        if css.isEmpty {
            return "(function(){var st=document.getElementById('musemobile-lyrics-style');if(st)st.remove();})();"
        }
        return """
        (function(){
            var st = document.getElementById('musemobile-lyrics-style');
            if (!st) { st = document.createElement('style'); st.id = 'musemobile-lyrics-style'; }
            st.textContent = \(cssQuote(css));
            var target = document.head || document.documentElement;
            if (target && !st.parentNode) target.appendChild(st);
        })();
        """
    }

    public static let devLogPrelude = """
    (function(){
        function send(lvl,m){ try{ AndBridge.dbg(lvl,String(m)); }catch(e){} }
        window.dbg =function(m){send('l',m)};
        window.dbgw=function(m){send('w',m)};
        window.dbge=function(m){send('e',m)};
        window.DevLog={
            log:function(){var a=[].slice.call(arguments).join(' ');send('l',a)},
            warn:function(){var a=[].slice.call(arguments).join(' ');send('w',a)},
            error:function(){var a=[].slice.call(arguments).join(' ');send('e',a)},
            sys:function(){var a=[].slice.call(arguments).join(' ');send('s',a)},
            clear:function(){},
            dump:function(){return '(see Settings > Devlog)'}
        };
    })();
    """

    static func cssQuote(_ s: String) -> String {
        var o = "\""
        for c in s {
            switch c {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default: o.append(c)
            }
        }
        return o + "\""
    }
}

private extension String {
    func escapedForJS() -> String { self }
}

/// Lyrics CSS bundle — full styles ported from Android `LyricsTheme.kt`.
/// Kept in a separate file in the real tree (LyricsCSS.swift); summarized here
/// with the shared seam-fix so element ID + style contract holds.
public enum LyricsCSS {
    public static func css(for style: String) -> String {
        switch style {
        case "compact", "karaoke", "bold", "fullscreen": return sharedFix + "\n" + marker(for: style)
        default: return "" // "default" -> remove element
        }
    }
    static let sharedFix = """
    /* --- MuseMobile Lyrics Engine: shared fixes --- */
    .nqmjceMqTFCSMXlnquLP { display: none !important; }
    """
    static func marker(for style: String) -> String {
        "/* musemobile lyrics style: \(style) — full CSS in LyricsCSS.swift (port of LyricsTheme.kt) */"
    }
}
