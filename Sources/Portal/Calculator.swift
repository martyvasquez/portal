import Foundation

/// Evaluates what's typed in the launcher as arithmetic: `8*8`, `10/2`, `(3+4)^2`, `200 + 15%`.
/// Unfinished input like `4+4+5+` shows what's there so far, so the answer doesn't flicker while typing.
enum Calculator {
    struct Answer: Equatable {
        let value: Double
        /// For the row: `1,234.5`.
        let display: String
        /// What Enter pastes: `1234.5`.
        let plain: String
    }

    static func evaluate(_ input: String) -> Answer? {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("=") { s.removeFirst() }
        // Drop a trailing operator or open paren, then close what's still open.
        while let last = s.last, "+-−*×x/÷^( ".contains(last) { s.removeLast() }
        guard s.contains(where: \.isNumber) else { return nil }
        let opens = s.filter { $0 == "(" }.count - s.filter { $0 == ")" }.count
        if opens > 0 { s += String(repeating: ")", count: opens) }

        guard let tokens = tokenize(s) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let result = parser.parse(), parser.operations > 0, result.isFinite else { return nil }
        let value = round(result)
        return Answer(value: value, display: format(value, grouped: true), plain: format(value, grouped: false))
    }

    /// Hides floating-point noise: `0.1+0.2` is `0.3`, not `0.30000000000000004`.
    private static func round(_ v: Double) -> Double {
        let r = Double(String(format: "%.12g", v)) ?? v
        return r == 0 ? 0 : r   // no "-0"
    }

    private static func format(_ v: Double, grouped: Bool) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = grouped
        f.groupingSeparator = ","
        f.usesSignificantDigits = true
        f.maximumSignificantDigits = 12
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    // MARK: - Parsing

    fileprivate enum Token: Equatable { case number(Double), op(Character), open, close }

    private static func tokenize(_ s: String) -> [Token]? {
        var tokens: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == " " { i = s.index(after: i); continue }
            if c.isNumber || c == "." {
                var j = i
                // "1,000" groups digits; a comma anywhere else isn't arithmetic.
                while j < s.endIndex, s[j].isASCII, s[j].isNumber || s[j] == "." || s[j] == "," { j = s.index(after: j) }
                let text = s[i..<j]
                let groups = text.split(separator: ",", omittingEmptySubsequences: false)
                if groups.count > 1, groups.dropFirst().contains(where: { $0.prefix { $0 != "." }.count != 3 }) { return nil }
                guard let n = Double(text.replacingOccurrences(of: ",", with: "")) else { return nil }
                tokens.append(.number(n))
                i = j
                continue
            }
            switch c {
            case "+": tokens.append(.op("+"))
            case "-", "−": tokens.append(.op("-"))
            case "*", "×", "x", "X": tokens.append(.op("*"))
            case "/", "÷": tokens.append(.op("/"))
            case "^": tokens.append(.op("^"))
            case "%": tokens.append(.op("%"))
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            default: return nil
            }
            i = s.index(after: i)
        }
        return tokens
    }

    /// expr := term (± term)*   term := unary ((*|/)? unary)*   unary := -unary | power
    /// power := postfix (^ unary)?   postfix := primary %*   primary := number | ( expr )
    fileprivate struct Parser {
        let tokens: [Token]
        var pos = 0
        /// Binary operations applied; a lone `8` or `-5` isn't a calculation.
        var operations = 0

        init(tokens: [Token]) { self.tokens = tokens }

        mutating func parse() -> Double? {
            guard let v = expr(), pos == tokens.count else { return nil }
            return v
        }

        private var peek: Token? { pos < tokens.count ? tokens[pos] : nil }

        private mutating func expr() -> Double? {
            guard var value = term()?.value else { return nil }
            while case .op(let c)? = peek, c == "+" || c == "-" {
                pos += 1
                guard let rhs = term() else { return nil }
                // "200 + 15%" is 200 plus 15% of 200, like a calculator.
                let amount = rhs.isPercent ? value * rhs.value : rhs.value
                value = c == "+" ? value + amount : value - amount
                operations += 1
            }
            return value
        }

        private mutating func term() -> (value: Double, isPercent: Bool)? {
            guard var result = unary() else { return nil }
            while true {
                if case .op(let c)? = peek, c == "*" || c == "/" {
                    pos += 1
                    guard let rhs = unary()?.value else { return nil }
                    if c == "/" && rhs == 0 { return nil }
                    result = (c == "*" ? result.value * rhs : result.value / rhs, false)
                } else if peek == .open {   // 2(3+4)
                    guard let rhs = unary()?.value else { return nil }
                    result = (result.value * rhs, false)
                } else {
                    return result
                }
                operations += 1
            }
        }

        private mutating func unary() -> (value: Double, isPercent: Bool)? {
            if case .op(let c)? = peek, c == "-" || c == "+" {
                pos += 1
                guard let v = unary() else { return nil }
                return c == "-" ? (-v.value, v.isPercent) : v
            }
            return power()
        }

        private mutating func power() -> (value: Double, isPercent: Bool)? {
            guard let base = postfix() else { return nil }
            guard peek == .op("^") else { return base }
            pos += 1
            guard let exponent = unary()?.value else { return nil }
            operations += 1
            return (pow(base.value, exponent), false)
        }

        private mutating func postfix() -> (value: Double, isPercent: Bool)? {
            guard var v = primary() else { return nil }
            var isPercent = false
            while peek == .op("%") {
                pos += 1
                v /= 100
                isPercent = true
            }
            return (v, isPercent)
        }

        private mutating func primary() -> Double? {
            switch peek {
            case .number(let n)?:
                pos += 1
                return n
            case .open?:
                pos += 1
                guard let v = expr(), peek == .close else { return nil }
                pos += 1
                return v
            default:
                return nil
            }
        }
    }
}
