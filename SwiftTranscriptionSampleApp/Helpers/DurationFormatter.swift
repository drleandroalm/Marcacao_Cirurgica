import Foundation

class DurationFormatter {
    private static let normalizationLocale = Locale(identifier: "pt_BR")

    static func format(_ input: String) -> String {
        let normalized = normalize(input)
        if normalized.isEmpty { return input }

        if let hhmm = matchHHMM(normalized) { return hhmm }

        let expanded = expandCompactUnits(in: normalized)
        let tokens = tokenize(expanded)

        let hourUnits: Set<String> = ["hora", "horas"]
        let minuteUnits: Set<String> = ["minuto", "minutos"]

        let hourComponent = extractComponent(for: hourUnits, tokens: tokens, treatHalfAsMinutes: false)
        let minuteComponent = extractComponent(for: minuteUnits, tokens: tokens, treatHalfAsMinutes: true)

        var hoursValue = hourComponent?.value
        var minutesValue = minuteComponent?.value

        if minutesValue == nil, let hourIndex = hourComponent?.index {
            let trailingTokens = collectTrailingNumberTokens(after: hourIndex, tokens: tokens)
            if trailingTokens.contains("meia") {
                minutesValue = 30
            } else if trailingTokens.contains("quarto") {
                minutesValue = 15
            } else if let parsed = PortugueseNumberParser.parse(trailingTokens) {
                minutesValue = parsed
            }
        }

        if minutesValue == nil {
            if expanded.contains("hora e meia") || expanded.contains("horas e meia") {
                minutesValue = 30
                if hoursValue == nil { hoursValue = 1 }
            } else if expanded.contains("hora e quarto") || expanded.contains("horas e quarto") {
                minutesValue = 15
            } else if expanded.contains("quarto de hora") {
                minutesValue = 15
            } else if expanded.contains("meia hora") {
                minutesValue = 30
            }
        }

        if hoursValue == nil && minutesValue == nil {
            let numbers = tokens.compactMap(Int.init)
            if numbers.count >= 2 {
                hoursValue = numbers[0]
                minutesValue = numbers[1]
            } else if let single = numbers.first {
                if single <= 59 {
                    minutesValue = single
                } else {
                    hoursValue = single
                }
            } else if let inferred = PortugueseNumberParser.firstNumber(in: tokens) {
                if inferred <= 59 {
                    minutesValue = inferred
                } else {
                    hoursValue = inferred
                }
            }
        }

        var totalMinutes = max(0, minutesValue ?? 0)
        var resolvedHours = max(0, hoursValue ?? 0)

        if totalMinutes >= 60 {
            resolvedHours += totalMinutes / 60
            totalMinutes = totalMinutes % 60
        }

        resolvedHours = min(resolvedHours, 23)

        return String(format: "%02d:%02d", resolvedHours, totalMinutes)
    }

    private static func matchHHMM(_ s: String) -> String? {
        let pattern = #"\b(\d{1,2})[:hH](\d{2})\b"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s) {
            let h = Int(s[r1]) ?? 0
            let m = Int(s[r2]) ?? 0
            return String(format: "%02d:%02d", h, m)
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let folded = lowered.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: normalizationLocale)
        let trimmed = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        return collapseWhitespace(in: trimmed.replacingOccurrences(of: "-", with: " "))
    }

    private static func expandCompactUnits(in text: String) -> String {
        var expanded = text
        let replacements: [(String, String)] = [
            (#"(\d{1,3})h(\d{2})(?:min|m)?"#, "$1 horas $2 minutos"),
            (#"(\d{1,3})h\b"#, "$1 horas"),
            (#"(\d{1,3})\s?(?:min|m)\b"#, "$1 minutos")
        ]

        for (pattern, template) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                expanded = regex.stringByReplacingMatches(
                    in: expanded,
                    range: NSRange(expanded.startIndex..., in: expanded),
                    withTemplate: template
                )
            }
        }

        return collapseWhitespace(in: expanded)
    }

    private static func tokenize(_ text: String) -> [String] {
        return text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private struct Component {
        let value: Int
        let index: Int
    }

    private static func extractComponent(for units: Set<String>, tokens: [String], treatHalfAsMinutes: Bool) -> Component? {
        for (index, token) in tokens.enumerated() where units.contains(token) {
            let numberTokens = tokensBeforeUnit(at: index, tokens: tokens)
            if treatHalfAsMinutes {
                if numberTokens.contains("meia") { return Component(value: 30, index: index) }
                if numberTokens.contains("quarto") { return Component(value: 15, index: index) }
            }

            if let numeric = numberTokens.compactMap(Int.init).last {
                return Component(value: numeric, index: index)
            }

            if let parsed = PortugueseNumberParser.parse(numberTokens) {
                return Component(value: parsed, index: index)
            }
        }
        return nil
    }

    private static func tokensBeforeUnit(at index: Int, tokens: [String]) -> [String] {
        guard index > 0 else { return [] }
        var result: [String] = []
        var current = index - 1

        while current >= 0 {
            let token = tokens[current]
            if token == "e" || PortugueseNumberParser.isNumberWord(token) || Int(token) != nil || token == "meia" || token == "quarto" {
                result.insert(token, at: 0)
                current -= 1
                continue
            }
            break
        }

        return result
    }

    private static func collectTrailingNumberTokens(after index: Int, tokens: [String]) -> [String] {
        guard index + 1 < tokens.count else { return [] }
        var collected: [String] = []
        var current = index + 1

        while current < tokens.count {
            let token = tokens[current]
            if token == "e" || token == "meia" || token == "quarto" || PortugueseNumberParser.isNumberWord(token) || Int(token) != nil {
                collected.append(token)
                current += 1
                continue
            }
            break
        }

        return collected
    }

    private static func collapseWhitespace(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\s+", options: []) else { return text }
        let collapsed = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum PortugueseNumberParser {
    private static let values: [String: Int] = [
        "zero": 0, "um": 1, "uma": 1, "dois": 2, "duas": 2, "tres": 3, "quatro": 4,
        "cinco": 5, "seis": 6, "sete": 7, "oito": 8, "nove": 9, "dez": 10, "onze": 11, "doze": 12,
        "treze": 13, "catorze": 14, "quatorze": 14, "quinze": 15, "dezesseis": 16, "dezessete": 17,
        "dezoito": 18, "dezenove": 19, "vinte": 20, "trinta": 30, "quarenta": 40, "cinquenta": 50,
        "sessenta": 60, "setenta": 70, "oitenta": 80, "noventa": 90
    ]

    static func parse(_ tokens: [String]) -> Int? {
        guard !tokens.isEmpty else { return nil }
        if let numeric = tokens.compactMap(Int.init).last { return numeric }

        var total = 0
        var consumed = false

        for token in tokens {
            if token == "e" { continue }
            guard let value = values[token] else { return consumed ? total : nil }
            total += value
            consumed = true
        }

        return consumed ? total : nil
    }

    static func isNumberWord(_ token: String) -> Bool {
        return values[token] != nil
    }

    static func firstNumber(in tokens: [String]) -> Int? {
        for token in tokens {
            if let numeric = Int(token) { return numeric }
            if let value = values[token] { return value }
        }
        return nil
    }
}
