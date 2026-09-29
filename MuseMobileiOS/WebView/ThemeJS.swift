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
/// STYLE element id (`musemobile-lyrics-style`) is owned by ThemeJS.lyricsStyleJS.
/// "default"/unknown returns "" so the caller removes the element.
public enum LyricsCSS {
    public static func css(for style: String) -> String {
        switch style {
        case "compact": return SHARED_FIX + COMPACT_CSS
        case "karaoke": return SHARED_FIX + KARAOKE_CSS
        case "bold": return SHARED_FIX + BOLD_CSS
        case "fullscreen": return SHARED_FIX + FULLSCREEN_CSS
        default: return "" // "default" -> remove element
        }
    }

    /// Back-compat alias for the shared seam-fix (lowercase name used previously).
    static var sharedFix: String { SHARED_FIX }

    static let SHARED_FIX = """
    /* --- MuseMobile Lyrics Engine: shared fixes --- */

    /* Old ~1-screen background layer -> hidden */
    .nqmjceMqTFCSMXlnquLP { display: none !important; }

    /* Paint the full-height lyric container chain with the dynamic album color */
    .bqldaBkacR41KxR2Z0jY,
    .NAOY0Orzgl4rd4__VtAw,
    .l2GQ00sPnkqe8YLHcfzL,
    .l2GQ00sPnkqe8YLHcfzL > div {
      background-color: var(--lyrics-color-background, #121212) !important;
      background-image: none !important;
      transition: background-color .6s ease !important;
    }

    /* Outer containers transparent */
    .WiwnWsPYbL585uUaVMp3,
    .main-view-container__scroll-node-child,
    .TheioDphh_FsNXvBiDj4 {
      background-color: transparent !important;
    }

    /* Viewport scroll */
    [data-overlayscrollbars-viewport] {
      overscroll-behavior-y: contain !important;
      -webkit-overflow-scrolling: touch;
    }

    /* Musixmatch credit */
    .upDNlpL8xEkxmKWWw9IF {
      margin: 16px 5% 0 !important;
      text-align: center !important;
      opacity: .45 !important;
    }
    .upDNlpL8xEkxmKWWw9IF .e-10860-text { font-size: 11px !important; }

    /* Reduce motion */
    @media (prefers-reduced-motion: reduce) {
      [data-testid="lyrics-line"] ._3s1DGSMxRHUVPuxgkoss { transition: none !important; }
    }
    """

    static let FULLSCREEN_CSS = """
    /* === FULLSCREEN: mobile fullscreen, album colors, glowing active line === */
    .l2GQ00sPnkqe8YLHcfzL {
      width: 100% !important;
      max-width: 100% !important;
      margin: 0 !important;
      padding: 8px 5% 140px 5% !important;
      box-sizing: border-box !important;
    }
    .bqldaBkacR41KxR2Z0jY {
      --lyrics-color-active:   #ffffff !important;
      --lyrics-color-inactive: rgba(255,255,255,.55) !important;
      --lyrics-color-passed:   rgba(255,255,255,.28) !important;
    }
    [data-testid="lyrics-line"] {
      margin: 0 !important;
      padding: 1px 0 !important;
      line-height: 1.45 !important;
      font-size: clamp(1.25rem, 2.4vw, 2.25rem) !important;
      overflow-wrap: anywhere !important;
      user-select: text !important;
    }
    [data-testid="lyrics-line"] ._3s1DGSMxRHUVPuxgkoss {
      font-size: 1em !important;
      font-weight: 700 !important;
      line-height: 1.45 !important;
      color: rgba(255,255,255,.55) !important;
      text-shadow: none !important;
      transition: font-size .3s cubic-bezier(.3,.7,.3,1),
                  color .4s ease, text-shadow .4s ease;
    }
    [data-testid="lyrics-line"].loNizikBbaCKyI9Gv8xg ._3s1DGSMxRHUVPuxgkoss {
      color: rgba(255,255,255,.28) !important;
    }
    [data-testid="lyrics-line"].dPaa_Hg0z0Ql_UBrV9uZ ._3s1DGSMxRHUVPuxgkoss {
      font-size: 1.35em !important;
      font-weight: 800 !important;
      line-height: 1.32 !important;
      color: #fff !important;
      text-shadow: 0 0 18px rgba(255,255,255,.28), 0 2px 6px rgba(0,0,0,.5) !important;
    }
    [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
      height: 20px !important; min-height: 20px !important; max-height: 20px !important;
      margin: 0 !important; padding: 0 !important; overflow: hidden !important;
    }
    [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt ._3s1DGSMxRHUVPuxgkoss {
      line-height: 0 !important;
    }
    @media (max-width: 768px) {
      .NAOY0Orzgl4rd4__VtAw { min-height: 100dvh !important; }
      .l2GQ00sPnkqe8YLHcfzL {
        padding:
          calc(8px + env(safe-area-inset-top))
          max(5%, env(safe-area-inset-right))
          calc(120px + env(safe-area-inset-bottom))
          max(5%, env(safe-area-inset-left)) !important;
      }
      [data-testid="lyrics-line"] { font-size: clamp(1.15rem, 5.5vw, 1.6rem) !important; }
      [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
        height: 18px !important; min-height: 18px !important; max-height: 18px !important;
      }
    }
    @media (max-height: 480px) and (orientation: landscape) {
      [data-testid="lyrics-line"] { font-size: clamp(1rem, 4.5vh, 1.3rem) !important; }
      [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
        height: 12px !important; min-height: 12px !important; max-height: 12px !important;
      }
      .l2GQ00sPnkqe8YLHcfzL { padding-bottom: 80px !important; }
    }
    """

    static let COMPACT_CSS = """
    /* === COMPACT: small, dense, zero glow === */
    .l2GQ00sPnkqe8YLHcfzL {
      width: 100% !important;
      max-width: 100% !important;
      margin: 0 !important;
      padding: 8px 5% 120px 5% !important;
      box-sizing: border-box !important;
    }
    .bqldaBkacR41KxR2Z0jY {
      --lyrics-color-active:   #ffffff !important;
      --lyrics-color-inactive: rgba(255,255,255,.5) !important;
      --lyrics-color-passed:   rgba(255,255,255,.25) !important;
    }
    [data-testid="lyrics-line"] {
      margin: 0 !important;
      padding: 1px 0 !important;
      line-height: 1.35 !important;
      font-size: clamp(.95rem, 1.9vw, 1.35rem) !important;
      overflow-wrap: anywhere !important;
      user-select: text !important;
    }
    [data-testid="lyrics-line"] ._3s1DGSMxRHUVPuxgkoss {
      font-size: 1em !important;
      font-weight: 600 !important;
      line-height: 1.35 !important;
      color: rgba(255,255,255,.5) !important;
      text-shadow: none !important;
      transition: font-size .2s ease, color .3s ease;
    }
    [data-testid="lyrics-line"].loNizikBbaCKyI9Gv8xg ._3s1DGSMxRHUVPuxgkoss {
      color: rgba(255,255,255,.25) !important;
    }
    [data-testid="lyrics-line"].dPaa_Hg0z0Ql_UBrV9uZ ._3s1DGSMxRHUVPuxgkoss {
      font-size: 1.12em !important;
      font-weight: 800 !important;
      line-height: 1.3 !important;
      color: #fff !important;
      text-shadow: none !important;
    }
    [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
      height: 14px !important; min-height: 14px !important; max-height: 14px !important;
      margin: 0 !important; padding: 0 !important; overflow: hidden !important;
    }
    [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt ._3s1DGSMxRHUVPuxgkoss {
      line-height: 0 !important;
    }
    @media (max-width: 768px) {
      .NAOY0Orzgl4rd4__VtAw { min-height: 100dvh !important; }
      .l2GQ00sPnkqe8YLHcfzL {
        padding:
          calc(8px + env(safe-area-inset-top))
          max(5%, env(safe-area-inset-right))
          calc(110px + env(safe-area-inset-bottom))
          max(5%, env(safe-area-inset-left)) !important;
      }
      [data-testid="lyrics-line"] { font-size: clamp(.9rem, 4.2vw, 1.15rem) !important; }
      [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
        height: 12px !important; min-height: 12px !important; max-height: 12px !important;
      }
    }
    @media (max-height: 480px) and (orientation: landscape) {
      [data-testid="lyrics-line"] { font-size: clamp(.85rem, 4vh, 1.05rem) !important; }
      [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
        height: 10px !important; min-height: 10px !important; max-height: 10px !important;
      }
      .l2GQ00sPnkqe8YLHcfzL { padding-bottom: 70px !important; }
    }
    """

    static let KARAOKE_CSS = """
    /* === KARAOKE: one giant line at a time === */
    .l2GQ00sPnkqe8YLHcfzL {
      width: 100% !important;
      max-width: 100% !important;
      margin: 0 !important;
      padding: 8px 5% 150px 5% !important;
      box-sizing: border-box !important;
    }
    .bqldaBkacR41KxR2Z0jY {
      --lyrics-color-active:   #ffffff !important;
      --lyrics-color-inactive: rgba(255,255,255,.22) !important;
      --lyrics-color-passed:   rgba(255,255,255,.10) !important;
    }
    [data-testid="lyrics-line"] {
      margin: 0 !important;
      padding: 2px 0 !important;
      line-height: 1.45 !important;
      font-size: clamp(1.2rem, 2.6vw, 2rem) !important;
      overflow-wrap: anywhere !important;
      user-select: text !important;
    }
    [data-testid="lyrics-line"] ._3s1DGSMxRHUVPuxgkoss {
      font-size: 1em !important;
      font-weight: 700 !important;
      line-height: 1.45 !important;
      color: rgba(255,255,255,.22) !important;
      text-shadow: none !important;
      transition: font-size .35s cubic-bezier(.3,.7,.3,1),
                  color .4s ease, text-shadow .4s ease;
    }
    [data-testid="lyrics-line"].loNizikBbaCKyI9Gv8xg ._3s1DGSMxRHUVPuxgkoss {
      color: rgba(255,255,255,.10) !important;
    }
    [data-testid="lyrics-line"].dPaa_Hg0z0Ql_UBrV9uZ ._3s1DGSMxRHUVPuxgkoss {
      font-size: 1.55em !important;
      font-weight: 900 !important;
      line-height: 1.28 !important;
      color: #fff !important;
      text-shadow: 0 0 30px rgba(255,255,255,.45), 0 2px 8px rgba(0,0,0,.55) !important;
    }
    [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
      height: 22px !important; min-height: 22px !important; max-height: 22px !important;
      margin: 0 !important; padding: 0 !important; overflow: hidden !important;
    }
    [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt ._3s1DGSMxRHUVPuxgkoss {
      line-height: 0 !important;
    }
    @media (max-width: 768px) {
      .NAOY0Orzgl4rd4__VtAw { min-height: 100dvh !important; }
      .l2GQ00sPnkqe8YLHcfzL {
        padding:
          calc(8px + env(safe-area-inset-top))
          max(5%, env(safe-area-inset-right))
          calc(130px + env(safe-area-inset-bottom))
          max(5%, env(safe-area-inset-left)) !important;
      }
      [data-testid="lyrics-line"] { font-size: clamp(1.1rem, 5vw, 1.6rem) !important; }
      [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
        height: 18px !important; min-height: 18px !important; max-height: 18px !important;
      }
    }
    @media (max-height: 480px) and (orientation: landscape) {
      [data-testid="lyrics-line"] { font-size: clamp(1rem, 4.5vh, 1.35rem) !important; }
      [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
        height: 12px !important; min-height: 12px !important; max-height: 12px !important;
      }
      .l2GQ00sPnkqe8YLHcfzL { padding-bottom: 90px !important; }
    }
    """

    static let BOLD_CSS = """
    /* === BOLD: all lines large, active just brighter === */
    .l2GQ00sPnkqe8YLHcfzL {
      width: 100% !important;
      max-width: 100% !important;
      margin: 0 !important;
      padding: 8px 5% 140px 5% !important;
      box-sizing: border-box !important;
    }
    .bqldaBkacR41KxR2Z0jY {
      --lyrics-color-active:   #ffffff !important;
      --lyrics-color-inactive: rgba(255,255,255,.72) !important;
      --lyrics-color-passed:   rgba(255,255,255,.42) !important;
    }
    [data-testid="lyrics-line"] {
      margin: 0 !important;
      padding: 1px 0 !important;
      line-height: 1.5 !important;
      font-size: clamp(1.3rem, 2.8vw, 2.4rem) !important;
      overflow-wrap: anywhere !important;
      user-select: text !important;
    }
    [data-testid="lyrics-line"] ._3s1DGSMxRHUVPuxgkoss {
      font-size: 1em !important;
      font-weight: 800 !important;
      line-height: 1.5 !important;
      color: rgba(255,255,255,.72) !important;
      text-shadow: none !important;
      transition: color .4s ease, text-shadow .4s ease;
    }
    [data-testid="lyrics-line"].loNizikBbaCKyI9Gv8xg ._3s1DGSMxRHUVPuxgkoss {
      color: rgba(255,255,255,.42) !important;
    }
    [data-testid="lyrics-line"].dPaa_Hg0z0Ql_UBrV9uZ ._3s1DGSMxRHUVPuxgkoss {
      color: #fff !important;
      text-shadow: 0 2px 10px rgba(0,0,0,.6) !important;
    }
    [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
      height: 20px !important; min-height: 20px !important; max-height: 20px !important;
      margin: 0 !important; padding: 0 !important; overflow: hidden !important;
    }
    [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt ._3s1DGSMxRHUVPuxgkoss {
      line-height: 0 !important;
    }
    @media (max-width: 768px) {
      .NAOY0Orzgl4rd4__VtAw { min-height: 100dvh !important; }
      .l2GQ00sPnkqe8YLHcfzL {
        padding:
          calc(8px + env(safe-area-inset-top))
          max(5%, env(safe-area-inset-right))
          calc(120px + env(safe-area-inset-bottom))
          max(5%, env(safe-area-inset-left)) !important;
      }
      [data-testid="lyrics-line"] { font-size: clamp(1.2rem, 5.8vw, 1.75rem) !important; }
      [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
        height: 16px !important; min-height: 16px !important; max-height: 16px !important;
      }
    }
    @media (max-height: 480px) and (orientation: landscape) {
      [data-testid="lyrics-line"] { font-size: clamp(1.05rem, 4.8vh, 1.4rem) !important; }
      [data-testid="lyrics-line"].WBNUk2iJWB8WkN8FaBOt {
        height: 12px !important; min-height: 12px !important; max-height: 12px !important;
      }
      .l2GQ00sPnkqe8YLHcfzL { padding-bottom: 80px !important; }
    }
    """
}
