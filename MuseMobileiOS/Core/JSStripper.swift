import Foundation

/// Port of Android `JsUtils.stripConsoleLogs`: replaces bare `console.log(...)`
/// calls with `void 0`, leaving strings/comments/regex intact.
/// Release builds strip; DebugOverlay builds keep logs.
public enum JSStripper {
    public static func stripConsoleLogs(_ code: String) -> String {
        guard code.contains("console") else { return code }
        // Lexer-lite: track string/comment/regex state, match console.log( ... ).
        var out = ""
        out.reserveCapacity(code.count)
        var i = code.startIndex
        let end = code.endIndex
        func isIdChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

        while i < end {
            let c = code[i]
            if c == "\"" || c == "'" || c == "`" {
                let q = c; out.append(c); i = code.index(after: i)
                while i < end {
                    let d = code[i]
                    out.append(d)
                    if d == "\\" { let n = code.index(after: i); if n < end { out.append(code[n]); i = code.index(after: n) } else { i = n }; continue }
                    i = code.index(after: i)
                    if d == q { break }
                }
                continue
            }
            if c == "/" && code.index(after: i) < end {
                let n = code[code.index(after: i)]
                if n == "/" || n == "*" {
                    // copy comment verbatim
                    if n == "/" {
                        while i < end && code[i] != "\n" { out.append(code[i]); i = code.index(after: i) }
                    } else {
                        out.append("/*"); i = code.index(i, offsetBy: 2, limitedBy: end) ?? end
                        while i < end {
                            if code[i] == "*" && code.index(after: i) < end && code[code.index(after: i)] == "/" {
                                out.append("*/"); i = code.index(i, offsetBy: 2, limitedBy: end) ?? end; break
                            }
                            out.append(code[i]); i = code.index(after: i)
                        }
                    }
                    continue
                }
            }
            // try match `console.log(`
            if code[i...].hasPrefix("console") {
                let prevOK: Bool = {
                    if out.isEmpty { return true }
                    let p = out.last!
                    return !(isIdChar(p) || p == ".")
                }()
                if prevOK {
                    var j = code.index(i, offsetBy: 7, limitedBy: end) ?? end
                    while j < end && code[j].isWhitespace { j = code.index(after: j) }
                    if j < end && code[j] == "." {
                        j = code.index(after: j)
                        while j < end && code[j].isWhitespace { j = code.index(after: j) }
                        if code[j...].hasPrefix("log") {
                            var k = code.index(j, offsetBy: 3, limitedBy: end) ?? end
                            while k < end && code[k].isWhitespace { k = code.index(after: k) }
                            if k < end && code[k] == "(" {
                                // find matching paren (nesting + strings)
                                var depth = 0, m = k, inStr: Character? = nil
                                while m < end {
                                    let ch = code[m]
                                    if let q = inStr {
                                        if ch == "\\" { m = code.index(after: m); if m < end { m = code.index(after: m) }; continue }
                                        if ch == q { inStr = nil }
                                    } else if ch == "\"" || ch == "'" || ch == "`" { inStr = ch }
                                    else if ch == "(" { depth += 1 }
                                    else if ch == ")" { depth -= 1; if depth == 0 { m = code.index(after: m); break } }
                                    m = code.index(after: m)
                                }
                                out.append("void 0"); i = m; continue
                            }
                        }
                    }
                }
            }
            out.append(c); i = code.index(after: i)
        }
        return out
    }
}
