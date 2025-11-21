import Foundation

class MilitaryTimeFormatter {

    private static let normalizationLocale = Locale(identifier: "pt_BR")
    
    // MARK: - Time Expression Mappings
    
    // Direct mappings for common Portuguese time expressions
    private static let timeExpressions: [String: String] = [
        // Morning (manhã) - 00:00 to 11:59
        "meia noite": "00:00",
        "zero hora": "00:00",
        "uma da manhã": "01:00",
        "uma e meia da manhã": "01:30",
        "duas da manhã": "02:00",
        "três da manhã": "03:00",
        "quatro da manhã": "04:00",
        "cinco da manhã": "05:00",
        "seis da manhã": "06:00",
        "seis e meia da manhã": "06:30",
        "sete da manhã": "07:00",
        "sete e quinze": "07:15",
        "sete e meia": "07:30",
        "sete e meia da manhã": "07:30",
        "sete e quarenta e cinco": "07:45",
        "oito da manhã": "08:00",
        "oito e meia": "08:30",
        "nove da manhã": "09:00",
        "nove e meia": "09:30",
        "dez da manhã": "10:00",
        "dez e meia": "10:30",
        "onze da manhã": "11:00",
        "onze e meia": "11:30",
        
        // Noon
        "meio dia": "12:00",
        "meio dia e quinze": "12:15",
        "meio dia e meia": "12:30",
        "meio dia e quarenta e cinco": "12:45",
        
        // Afternoon/Evening (tarde/noite) - 13:00 to 23:59
        "uma da tarde": "13:00",
        "uma e quinze da tarde": "13:15",
        "uma e meia da tarde": "13:30",
        "uma e quarenta e cinco da tarde": "13:45",
        "duas da tarde": "14:00",
        "duas e quinze da tarde": "14:15",
        "duas e meia da tarde": "14:30",
        "duas e quarenta e cinco da tarde": "14:45",
        "três da tarde": "15:00",
        "três e meia da tarde": "15:30",
        "quatro da tarde": "16:00",
        "quatro e meia da tarde": "16:30",
        "cinco da tarde": "17:00",
        "cinco e quinze da tarde": "17:15",
        "cinco e meia da tarde": "17:30",
        "cinco e quarenta e cinco": "17:45",
        "cinco e quarenta e cinco da tarde": "17:45",
        "seis da tarde": "18:00",
        "seis e meia da tarde": "18:30",
        "sete da noite": "19:00",
        "sete e meia da noite": "19:30",
        "oito da noite": "20:00",
        "oito e meia da noite": "20:30",
        "nove da noite": "21:00",
        "nove e meia da noite": "21:30",
        "dez da noite": "22:00",
        "dez e meia da noite": "22:30",
        "onze da noite": "23:00",
        "onze e meia da noite": "23:30"
    ]

    private static let normalizedTimeExpressions: [String: String] = {
        var mapping: [String: String] = [:]
        for (key, value) in timeExpressions {
            mapping[normalizeKey(key)] = value
        }
        return mapping
    }()

    private static let normalizedPrefixes: [String] = {
        let prefixes = ["às", "as", "por volta das", "aproximadamente", "cerca de"]
        return prefixes.map { normalizeKey($0) }
    }()
    
    // Number word mappings
    private static let numberWords: [String: Int] = [
        "zero": 0, "uma": 1, "um": 1, "dois": 2, "duas": 2,
        "tres": 3, "quatro": 4, "cinco": 5, "seis": 6,
        "sete": 7, "oito": 8, "nove": 9, "dez": 10,
        "onze": 11, "doze": 12, "treze": 13, "catorze": 14,
        "quatorze": 14, "quinze": 15, "dezesseis": 16,
        "dezessete": 17, "dezoito": 18, "dezenove": 19,
        "vinte": 20, "trinta": 30, "quarenta": 40,
        "cinquenta": 50
    ]
    
    // MARK: - Main Formatting Method
    
    static func format(_ input: String) -> String {
        let normalized = normalizePortuguese(input)
        
        // Try direct mapping first
        if let directMatch = normalizedTimeExpressions[normalized] {
            return directMatch
        }
        
        // Check if already in military format (HH:MM)
        if isMilitaryFormat(normalized) {
            return validateAndFormatMilitaryTime(normalized)
        }
        
        // Check if it's a numeric format (e.g., "14:30", "1430")
        if let militaryTime = parseNumericTime(normalized) {
            return militaryTime
        }
        
        // Parse complex time expressions
        let (hour, minute, period) = parseTimeComponents(normalized)
        
        if hour >= 0 && hour <= 24 {
            var militaryHour = hour
            
            // Convert to military time based on period
            if period == "tarde" || period == "noite" {
                if hour < 12 && hour != 0 {
                    militaryHour += 12
                }
            } else if period == "manha" {
                if hour == 12 {
                    militaryHour = 0 // Midnight
                }
            }
            
            // Handle special case of "meio dia" (noon)
            if normalized.contains("meio dia") {
                militaryHour = 12
            }
            
            return String(format: "%02d:%02d", militaryHour, minute)
        }
        
        // Fallback: try to extract any time-like pattern
        return extractTimePattern(normalized) ?? "00:00"
    }
    
    // MARK: - Helper Methods
    
    private static func normalizeKey(_ text: String) -> String {
        let lowered = text.lowercased()
        let folded = lowered.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: normalizationLocale)
        var cleaned = folded.replacingOccurrences(of: "-", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "[,.]", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizePortuguese(_ text: String) -> String {
        var normalized = normalizeKey(text)

        for prefix in normalizedPrefixes {
            if normalized.hasPrefix(prefix + " ") {
                normalized = String(normalized.dropFirst(prefix.count + 1))
            } else if normalized == prefix {
                normalized = ""
            }
        }

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func isMilitaryFormat(_ text: String) -> Bool {
        let pattern = #"^\d{1,2}:\d{2}$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    
    private static func validateAndFormatMilitaryTime(_ time: String) -> String {
        let components = time.split(separator: ":")
        if components.count == 2,
           let hour = Int(components[0]),
           let minute = Int(components[1]),
           hour >= 0, hour <= 23,
           minute >= 0, minute <= 59 {
            return String(format: "%02d:%02d", hour, minute)
        }
        return "00:00"
    }
    
    private static func parseNumericTime(_ text: String) -> String? {
        // Handle formats like "1430" or "0730"
        let digitsOnly = text.filter { $0.isNumber }
        
        if digitsOnly.count == 3 || digitsOnly.count == 4 {
            let hour: Int
            let minute: Int
            
            if digitsOnly.count == 3 {
                // Format: "730" -> "07:30"
                hour = Int(String(digitsOnly.prefix(1))) ?? 0
                minute = Int(String(digitsOnly.suffix(2))) ?? 0
            } else {
                // Format: "1430" -> "14:30"
                hour = Int(String(digitsOnly.prefix(2))) ?? 0
                minute = Int(String(digitsOnly.suffix(2))) ?? 0
            }
            
            if hour >= 0, hour <= 23, minute >= 0, minute <= 59 {
                return String(format: "%02d:%02d", hour, minute)
            }
        }
        
        return nil
    }
    
    private static func parseTimeComponents(_ text: String) -> (hour: Int, minute: Int, period: String) {
        var hour = -1
        var minute = 0
        var period = ""
        
        // Detect period (manhã, tarde, noite)
        if text.contains("manha") || text.contains("madrugada") {
            period = "manha"
        } else if text.contains("tarde") {
            period = "tarde"
        } else if text.contains("noite") {
            period = "noite"
        }
        
        // Parse hour
        let words = text.split(separator: " ").map(String.init)
        
        for (index, word) in words.enumerated() {
            // Check for number words
            if let hourNum = numberWords[word] {
                hour = hourNum
            }
            // Check for numeric values
            else if let hourNum = Int(word) {
                hour = hourNum
            }
            
            // Parse minutes
            if index > 0 && words[index - 1] == "e" {
                if word == "meia" {
                    minute = 30
                } else if word == "quinze" {
                    minute = 15
                } else if word == "quarenta" && index + 2 < words.count && words[index + 1] == "e" && words[index + 2] == "cinco" {
                    minute = 45
                } else if let minNum = numberWords[word] {
                    minute = minNum
                } else if let minNum = Int(word) {
                    minute = minNum
                }
            }
        }
        
        // Handle "e meia" (half hour)
        if text.contains("e meia") {
            minute = 30
        }
        
        // Handle compound minutes like "quarenta e cinco"
        if text.contains("quarenta e cinco") {
            minute = 45
        } else if text.contains("quinze") && !text.contains("e quinze") {
            // Sometimes "quinze" is used alone to mean X:15
            if let quinzeIndex = words.firstIndex(of: "quinze"),
               quinzeIndex > 0,
               words[quinzeIndex - 1] != "e" {
                hour = numberWords[words[quinzeIndex - 1]] ?? hour
                minute = 15
            }
        }
        
        return (hour, minute, period)
    }
    
    private static func extractTimePattern(_ text: String) -> String? {
        // Try to extract HH:MM pattern
        let pattern = #"(\d{1,2}):(\d{2})"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let hourRange = Range(match.range(at: 1), in: text)!
            let minuteRange = Range(match.range(at: 2), in: text)!
            
            let hour = Int(text[hourRange]) ?? 0
            let minute = Int(text[minuteRange]) ?? 0
            
            if hour >= 0, hour <= 23, minute >= 0, minute <= 59 {
                return String(format: "%02d:%02d", hour, minute)
            }
        }
        
        // Try to extract hour only (e.g., "às 14")
        let hourPattern = #"(\d{1,2})(?:\s*(?:hora|horas))?"#
        if let regex = try? NSRegularExpression(pattern: hourPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let hourRange = Range(match.range(at: 1), in: text)!
            let hour = Int(text[hourRange]) ?? 0
            
            if hour >= 0, hour <= 23 {
                return String(format: "%02d:00", hour)
            }
        }
        
        return nil
    }
    
    // MARK: - Validation
    
    static func isValidMilitaryTime(_ time: String) -> Bool {
        let components = time.split(separator: ":")
        if components.count == 2,
           let hour = Int(components[0]),
           let minute = Int(components[1]) {
            return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59
        }
        return false
    }
}