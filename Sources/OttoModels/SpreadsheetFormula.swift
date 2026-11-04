import Foundation

// MARK: - Function catalog

/// One spreadsheet function, as shown in formula autocomplete.
public struct SpreadsheetFunction: Sendable, Equatable {
  public let name: String
  public let signature: String
  public let summary: String

  public init(name: String, signature: String, summary: String) {
    self.name = name
    self.signature = signature
    self.summary = summary
  }
}

/// Every function the formula engine supports.
public enum SpreadsheetFunctions {
  /// All supported functions, sorted by name.
  public static let all: [SpreadsheetFunction] = entries.map { name, signature, summary in
    SpreadsheetFunction(name: name, signature: signature, summary: summary)
  }
  .sorted { $0.name < $1.name }

  /// The most-used functions, listed first when the typed prefix is short.
  static let common = ["SUM", "AVERAGE", "IF", "VLOOKUP", "COUNT", "MAX", "MIN"]

  /// Functions whose name starts with `prefix` (case-insensitive). For prefixes of up to two
  /// characters the common functions come first; otherwise results are alphabetical.
  public static func matching(prefix: String) -> [SpreadsheetFunction] {
    var needle = prefix.trimmingCharacters(in: .whitespaces).uppercased()
    if needle.hasPrefix("=") { needle.removeFirst() }
    let hits = all.filter { $0.name.hasPrefix(needle) }
    guard needle.count <= 2 else { return hits }
    func rank(_ function: SpreadsheetFunction) -> Int {
      common.firstIndex(of: function.name) ?? common.count
    }
    return hits.enumerated()
      .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
      .map(\.element)
  }

  private static let entries: [(String, String, String)] = [
    ("ABS", "ABS(value)", "Returns the absolute value of a number."),
    ("AND", "AND(logical1, [logical2, ...])", "Returns TRUE when every argument is true."),
    ("AVERAGE", "AVERAGE(value1, [value2, ...])", "Returns the mean of the numbers."),
    (
      "AVERAGEIF", "AVERAGEIF(range, criterion, [average_range])",
      "Averages the cells that meet a criterion."
    ),
    (
      "AVERAGEIFS", "AVERAGEIFS(average_range, criteria_range1, criterion1, ...)",
      "Averages the cells that meet every criterion."
    ),
    (
      "CEILING", "CEILING(value, [significance])",
      "Rounds a number up to the nearest multiple of significance."
    ),
    ("CONCAT", "CONCAT(value1, [value2, ...])", "Joins values into one piece of text."),
    ("CONCATENATE", "CONCATENATE(value1, [value2, ...])", "Joins values into one piece of text."),
    ("COUNT", "COUNT(value1, [value2, ...])", "Counts the numeric values."),
    ("COUNTA", "COUNTA(value1, [value2, ...])", "Counts the non-empty values."),
    ("COUNTBLANK", "COUNTBLANK(range)", "Counts the empty cells in a range."),
    ("COUNTIF", "COUNTIF(range, criterion)", "Counts the cells that meet a criterion."),
    (
      "COUNTIFS", "COUNTIFS(criteria_range1, criterion1, ...)",
      "Counts the cells that meet every criterion."
    ),
    ("DATE", "DATE(year, month, day)", "Builds a date from a year, month and day."),
    ("DAY", "DAY(date)", "Returns the day of the month of a date."),
    ("DAYS", "DAYS(end_date, start_date)", "Returns the number of days between two dates."),
    ("EXP", "EXP(exponent)", "Returns e raised to a power."),
    (
      "FIND", "FIND(search_for, text, [start])",
      "Finds the position of text within text, case-sensitively."
    ),
    (
      "FLOOR", "FLOOR(value, [significance])",
      "Rounds a number down to the nearest multiple of significance."
    ),
    (
      "HLOOKUP", "HLOOKUP(key, range, row, [is_sorted])",
      "Looks up a key in the first row and returns a value from the same column."
    ),
    (
      "IF", "IF(condition, value_if_true, [value_if_false])",
      "Returns one value when a condition is true and another when it is false."
    ),
    (
      "IFERROR", "IFERROR(value, value_if_error)",
      "Returns a fallback when a value is an error."
    ),
    ("IFNA", "IFNA(value, value_if_na)", "Returns a fallback when a value is #N/A."),
    (
      "IFS", "IFS(condition1, value1, [condition2, value2, ...])",
      "Returns the value for the first condition that is true."
    ),
    (
      "INDEX", "INDEX(range, row, [column])",
      "Returns the cell at a row and column within a range."
    ),
    ("INT", "INT(value)", "Rounds a number down to the nearest integer."),
    ("ISBLANK", "ISBLANK(value)", "Returns TRUE when a cell is empty."),
    ("ISERROR", "ISERROR(value)", "Returns TRUE when a value is an error."),
    ("ISNUMBER", "ISNUMBER(value)", "Returns TRUE when a value is a number."),
    ("ISTEXT", "ISTEXT(value)", "Returns TRUE when a value is text."),
    ("LARGE", "LARGE(range, k)", "Returns the k-th largest number."),
    ("LEFT", "LEFT(text, [count])", "Returns characters from the start of text."),
    ("LEN", "LEN(text)", "Returns the number of characters in text."),
    ("LN", "LN(value)", "Returns the natural logarithm of a number."),
    ("LOG10", "LOG10(value)", "Returns the base-10 logarithm of a number."),
    ("LOWER", "LOWER(text)", "Converts text to lowercase."),
    (
      "MATCH", "MATCH(key, range, [match_type])",
      "Returns the position of a key in a row or column."
    ),
    ("MAX", "MAX(value1, [value2, ...])", "Returns the largest number."),
    ("MEDIAN", "MEDIAN(value1, [value2, ...])", "Returns the middle number."),
    ("MID", "MID(text, start, count)", "Returns characters from the middle of text."),
    ("MIN", "MIN(value1, [value2, ...])", "Returns the smallest number."),
    ("MOD", "MOD(dividend, divisor)", "Returns the remainder after division."),
    ("MODE", "MODE(value1, [value2, ...])", "Returns the most frequent number."),
    ("MONTH", "MONTH(date)", "Returns the month of a date."),
    ("NOT", "NOT(logical)", "Reverses a logical value."),
    ("NOW", "NOW()", "Returns the current date and time."),
    ("OR", "OR(logical1, [logical2, ...])", "Returns TRUE when any argument is true."),
    ("PI", "PI()", "Returns the value of pi."),
    ("POWER", "POWER(base, exponent)", "Raises a number to a power."),
    ("PRODUCT", "PRODUCT(value1, [value2, ...])", "Multiplies the numbers together."),
    ("PROPER", "PROPER(text)", "Capitalises the first letter of each word."),
    ("RAND", "RAND()", "Returns a random number between 0 and 1."),
    (
      "RANDBETWEEN", "RANDBETWEEN(low, high)",
      "Returns a random integer between two values."
    ),
    (
      "RANK", "RANK(value, range, [ascending])",
      "Returns the rank of a number within a list."
    ),
    (
      "REPLACE", "REPLACE(text, start, count, new_text)",
      "Replaces part of text by position."
    ),
    ("REPT", "REPT(text, times)", "Repeats text a number of times."),
    ("RIGHT", "RIGHT(text, [count])", "Returns characters from the end of text."),
    ("ROUND", "ROUND(value, [places])", "Rounds a number to a number of decimal places."),
    ("ROUNDDOWN", "ROUNDDOWN(value, [places])", "Rounds a number toward zero."),
    ("ROUNDUP", "ROUNDUP(value, [places])", "Rounds a number away from zero."),
    (
      "SEARCH", "SEARCH(search_for, text, [start])",
      "Finds the position of text within text, ignoring case."
    ),
    ("SMALL", "SMALL(range, k)", "Returns the k-th smallest number."),
    ("SQRT", "SQRT(value)", "Returns the square root of a number."),
    ("STDEV", "STDEV(value1, [value2, ...])", "Returns the sample standard deviation."),
    (
      "SUBSTITUTE", "SUBSTITUTE(text, search_for, replace_with, [occurrence])",
      "Replaces existing text with new text."
    ),
    ("SUM", "SUM(value1, [value2, ...])", "Adds the numbers together."),
    ("SUMIF", "SUMIF(range, criterion, [sum_range])", "Adds the cells that meet a criterion."),
    (
      "SUMIFS", "SUMIFS(sum_range, criteria_range1, criterion1, ...)",
      "Adds the cells that meet every criterion."
    ),
    (
      "SUMPRODUCT", "SUMPRODUCT(range1, [range2, ...])",
      "Multiplies matching cells in ranges and adds the results."
    ),
    (
      "SWITCH", "SWITCH(expression, case1, value1, ..., [default])",
      "Returns the value for the first case that matches the expression."
    ),
    ("TEXT", "TEXT(value, format)", "Formats a number or date as text."),
    (
      "TEXTJOIN", "TEXTJOIN(delimiter, ignore_empty, text1, [text2, ...])",
      "Joins values with a delimiter."
    ),
    ("TODAY", "TODAY()", "Returns today's date."),
    ("TRIM", "TRIM(text)", "Removes extra spaces from text."),
    ("UPPER", "UPPER(text)", "Converts text to uppercase."),
    ("VALUE", "VALUE(text)", "Converts text to a number."),
    ("VAR", "VAR(value1, [value2, ...])", "Returns the sample variance."),
    (
      "VLOOKUP", "VLOOKUP(key, range, column, [is_sorted])",
      "Looks up a key in the first column and returns a value from the same row."
    ),
    (
      "XLOOKUP", "XLOOKUP(key, lookup_range, return_range, [if_not_found], [match_mode])",
      "Looks up a key and returns the matching item from another range."
    ),
    (
      "XOR", "XOR(logical1, [logical2, ...])",
      "Returns TRUE when an odd number of arguments are true."
    ),
    ("YEAR", "YEAR(date)", "Returns the year of a date."),
  ]
}

// MARK: - Formula text helpers

/// Text-level helpers for formula editing: reference detection, Excel-style copy shifting and
/// caret context for autocomplete.
public enum SpreadsheetFormula {
  /// A cell or range reference found in formula text.
  public struct Reference: Equatable, Sendable {
    public let range: Range<String.Index>
    public let start: CellAddress
    public let end: CellAddress
    /// The tab named before `!`, or nil for this tab.
    public let sheet: String?

    public init(
      range: Range<String.Index>, start: CellAddress, end: CellAddress, sheet: String? = nil
    ) {
      self.range = range
      self.start = start
      self.end = end
      self.sheet = sheet
    }
  }

  /// Cell/range references in a formula, in order. Text inside quotes and function names are
  /// ignored; a tab prefix (`Sales!`) is reported in `sheet`. `end == start` for single cells.
  public static func references(in formula: String) -> [Reference] {
    spans(in: formula).map { span in
      Reference(
        range: span.range, start: span.start.address, end: (span.end ?? span.start).address,
        sheet: span.sheet?.name)
    }
  }

  /// How a tab is written in a formula: bare when it reads as a plain name, otherwise quoted
  /// (`'Q1 data'`, `'2024'`, `'A1'`), with inner quotes doubled.
  public static func sheetPrefix(_ name: String) -> String {
    let plain =
      name.first.map { $0.isLetter || $0 == "_" } == true
      && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
      && name.allSatisfy(\.isASCII) && CellAddress(name) == nil
      && !["TRUE", "FALSE"].contains(name.uppercased())
    return plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
  }

  /// Rewrites references to a renamed tab, as Excel does. Other text is left alone.
  public static func renamingSheet(_ raw: String, from old: String, to new: String) -> String {
    guard raw.hasPrefix("=") else { return raw }
    var output = ""
    var cursor = raw.startIndex
    for span in spans(in: raw) {
      guard let sheet = span.sheet, sheet.name.caseInsensitiveCompare(old) == .orderedSame
      else { continue }
      // Separate appends: older Swift compilers find the chained `+` ambiguous here.
      output += raw[cursor..<sheet.range.lowerBound]
      output += sheetPrefix(new)
      output += "!"
      cursor = sheet.range.upperBound
    }
    output += raw[cursor...]
    return output
  }

  /// Shifts relative references by the given offsets, as when copying a formula Excel-style.
  /// `$`-anchored parts stay put; references pushed off the grid become `#REF!`. Text that is
  /// not a formula (no leading `=`) is returned unchanged.
  public static func shifted(_ raw: String, rows: Int, columns: Int) -> String {
    guard raw.hasPrefix("="), rows != 0 || columns != 0 else { return raw }
    var output = ""
    var cursor = raw.startIndex
    for span in spans(in: raw) {
      output += raw[cursor..<span.range.lowerBound]
      let parts = [span.start, span.end].compactMap { $0?.shifted(rows: rows, columns: columns) }
      output += parts.count == (span.end == nil ? 1 : 2) ? parts.joined(separator: ":") : "#REF!"
      cursor = span.range.upperBound
    }
    output += raw[cursor...]
    return output
  }

  /// True when clicking a cell should insert a reference at `caret`: the formula starts with
  /// `=`, the caret is outside quotes, and the text before it (ignoring trailing spaces) ends
  /// with `=`, `(`, `,`, an operator or `:`.
  public static func acceptsReference(_ formula: String, caret: String.Index) -> Bool {
    guard formula.hasPrefix("=") else { return false }
    let before = formula[..<min(max(caret, formula.startIndex), formula.endIndex)]
    guard before.filter({ $0 == "\"" }).count.isMultiple(of: 2) else { return false }
    guard let last = before.last(where: { $0 != " " }) else { return false }
    return "=(,+-*/^&<>:".contains(last)
  }

  /// The upper-cased name of the innermost function whose argument list contains `caret`.
  public static func enclosingFunction(_ formula: String, caret: String.Index) -> String? {
    let limit = min(max(caret, formula.startIndex), formula.endIndex)
    var stack: [String?] = []
    var pendingName: String?
    var index = formula.startIndex
    while index < limit {
      let character = formula[index]
      if character == "\"" {
        index = skipString(formula, from: index, limit: limit)
        pendingName = nil
      } else if isNameStart(character) {
        let start = index
        index = skipName(formula, from: index, limit: limit)
        pendingName = formula[start..<index].uppercased()
      } else if character.isASCIIDigit || character == "." {
        index = skipNumber(formula, from: index, limit: limit)
        pendingName = nil
      } else {
        if character == "(" {
          stack.append(pendingName)
        } else if character == ")" {
          _ = stack.popLast()
        }
        if !character.isWhitespace { pendingName = nil }
        index = formula.index(after: index)
      }
    }
    return stack.last(where: { $0 != nil }) ?? nil
  }

  // MARK: Scanning

  /// One A1 address as written, keeping its `$` anchors.
  struct AddressToken: Equatable {
    var address: CellAddress
    var absoluteColumn: Bool
    var absoluteRow: Bool

    init?(_ text: Substring) {
      guard let address = CellAddress(String(text)) else { return nil }
      self.address = address
      absoluteColumn = text.hasPrefix("$")
      absoluteRow = text.dropFirst().contains("$")
    }

    func shifted(rows: Int, columns: Int) -> String? {
      let column = address.column + (absoluteColumn ? 0 : columns)
      let row = address.row + (absoluteRow ? 0 : rows)
      guard (0..<16_384).contains(column), (0..<1_048_576).contains(row) else { return nil }
      return (absoluteColumn ? "$" : "") + CellAddress.columnName(column) + (absoluteRow ? "$" : "")
        + String(row + 1)
    }
  }

  struct Span {
    var range: Range<String.Index>
    var start: AddressToken
    var end: AddressToken?
    /// The tab prefix, including its `!`.
    var sheet: (name: String, range: Range<String.Index>)?
  }

  static func spans(in formula: String) -> [Span] {
    var spans: [Span] = []
    let end = formula.endIndex
    var index = formula.startIndex
    func skipSpaces(_ from: String.Index) -> String.Index {
      var position = from
      while position < end, formula[position].isWhitespace {
        position = formula.index(after: position)
      }
      return position
    }
    var pendingSheet: (name: String, range: Range<String.Index>)?
    while index < end {
      // A tab prefix only belongs to the address written straight after it.
      let sheet = pendingSheet
      pendingSheet = nil
      let character = formula[index]
      if character == "'" {
        let start = index
        var name = ""
        index = formula.index(after: index)
        while index < end {
          if formula[index] == "'" {
            let next = formula.index(after: index)
            if next < end, formula[next] == "'" {
              name.append("'")
              index = formula.index(after: next)
              continue
            }
            index = next
            break
          }
          name.append(formula[index])
          index = formula.index(after: index)
        }
        if index < end, formula[index] == "!" {
          index = formula.index(after: index)
          pendingSheet = (name, start..<index)
        }
      } else if character == "\"" {
        index = skipString(formula, from: index, limit: end)
      } else if character.isASCIIDigit || character == "." {
        index = skipNumber(formula, from: index, limit: end)
      } else if isNameStart(character) {
        let start = index
        index = skipName(formula, from: index, limit: end)
        if index < end, formula[index] == "!" {
          let name = String(formula[start..<index])
          index = formula.index(after: index)
          pendingSheet = (name, start..<index)
          continue
        }
        let next = skipSpaces(index)
        if next < end, formula[next] == "(" { continue }
        guard let first = AddressToken(formula[start..<index]) else { continue }
        var colon = next
        if colon < end, formula[colon] == ":" {
          colon = skipSpaces(formula.index(after: colon))
          if colon < end, isNameStart(formula[colon]) {
            let secondEnd = skipName(formula, from: colon, limit: end)
            if let second = AddressToken(formula[colon..<secondEnd]) {
              spans.append(
                Span(range: start..<secondEnd, start: first, end: second, sheet: sheet))
              index = secondEnd
              continue
            }
          }
        }
        spans.append(Span(range: start..<index, start: first, end: nil, sheet: sheet))
      } else {
        index = formula.index(after: index)
      }
    }
    return spans
  }

  private static func isNameStart(_ character: Character) -> Bool {
    character == "$" || character == "_" || character.isLetter
  }

  private static func skipName(_ text: String, from: String.Index, limit: String.Index)
    -> String.Index
  {
    var index = from
    while index < limit,
      isNameStart(text[index]) || text[index].isASCIIDigit || text[index] == "."
    {
      index = text.index(after: index)
    }
    return index
  }

  private static func skipNumber(_ text: String, from: String.Index, limit: String.Index)
    -> String.Index
  {
    var index = from
    while index < limit, text[index].isASCIIDigit || text[index] == "." {
      index = text.index(after: index)
    }
    if index < limit, text[index] == "e" || text[index] == "E" {
      var next = text.index(after: index)
      if next < limit, text[next] == "+" || text[next] == "-" { next = text.index(after: next) }
      if next < limit, text[next].isASCIIDigit {
        index = next
        while index < limit, text[index].isASCIIDigit { index = text.index(after: index) }
      }
    }
    return index
  }

  /// Skips a quoted string (with doubled-quote escapes) starting at the opening quote.
  private static func skipString(_ text: String, from: String.Index, limit: String.Index)
    -> String.Index
  {
    var index = text.index(after: from)
    while index < limit {
      if text[index] == "\"" {
        let next = text.index(after: index)
        if next < limit, text[next] == "\"" {
          index = text.index(after: next)
          continue
        }
        return next
      }
      index = text.index(after: index)
    }
    return limit
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - Criteria

/// A SUMIF/COUNTIF-style criterion such as `">5"`, `"<>done"`, `"a*"` or a plain value.
struct SpreadsheetCriterion {
  enum Operand {
    case blank
    case number(Double)
    case bool(Bool)
    case text(String)
  }

  var op: String
  var operand: Operand

  init(_ value: CellValue) {
    switch value {
    case .number(let number): (op, operand) = ("=", .number(number))
    case .bool(let flag): (op, operand) = ("=", .bool(flag))
    case .empty, .error: (op, operand) = ("=", .number(0))
    case .text(let text):
      var rest = Substring(text)
      op = "="
      for candidate in [">=", "<=", "<>", ">", "<", "="] where rest.hasPrefix(candidate) {
        op = candidate
        rest = rest.dropFirst(candidate.count)
        break
      }
      if rest.isEmpty {
        operand = op == "=" || op == "<>" ? .blank : .text("")
      } else if let number = CellValue.parseNumber(String(rest)) {
        operand = .number(number)
      } else if rest.uppercased() == "TRUE" || rest.uppercased() == "FALSE" {
        operand = .bool(rest.uppercased() == "TRUE")
      } else {
        operand = .text(String(rest))
      }
    }
  }

  func matches(_ cell: CellValue) -> Bool {
    switch operand {
    case .blank:
      let isBlank = cell == .empty || cell == .text("")
      return op == "=" ? isBlank : !isBlank
    case .number(let target):
      let value: Double?
      switch cell {
      case .number(let number): value = number
      case .text(let text): value = CellValue.parseNumber(text)
      default: value = nil
      }
      guard let value else { return op == "<>" }
      return Self.holds(
        op,
        value == target ? .orderedSame : (value < target ? .orderedAscending : .orderedDescending))
    case .bool(let target):
      guard case .bool(let flag) = cell else { return op == "<>" }
      return Self.holds(
        op, flag == target ? .orderedSame : (!flag ? .orderedAscending : .orderedDescending))
    case .text(let pattern):
      guard case .text(let text) = cell else { return op == "<>" }
      if op == "=" || op == "<>" {
        return Self.wildcardMatch(pattern, text) == (op == "=")
      }
      return Self.holds(op, text.caseInsensitiveCompare(pattern))
    }
  }

  private static func holds(_ op: String, _ order: ComparisonResult) -> Bool {
    switch op {
    case "=": order == .orderedSame
    case "<>": order != .orderedSame
    case "<": order == .orderedAscending
    case ">": order == .orderedDescending
    case "<=": order != .orderedDescending
    default: order != .orderedAscending
    }
  }

  static func hasWildcards(_ pattern: String) -> Bool {
    pattern.contains { "*?~".contains($0) }
  }

  /// Case-insensitive match where `*` is any run, `?` any one character and `~` escapes.
  static func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
    enum Token: Equatable {
      case any
      case one
      case literal(Character)
    }
    var tokens: [Token] = []
    var escaped = false
    for character in pattern.lowercased() {
      if escaped {
        tokens.append(.literal(character))
        escaped = false
      } else if character == "~" {
        escaped = true
      } else {
        tokens.append(character == "*" ? .any : character == "?" ? .one : .literal(character))
      }
    }
    if escaped { tokens.append(.literal("~")) }
    let characters = Array(text.lowercased())
    var p = 0
    var t = 0
    var star = -1
    var mark = 0
    while t < characters.count {
      if p < tokens.count, tokens[p] == .one || tokens[p] == .literal(characters[t]) {
        p += 1
        t += 1
      } else if p < tokens.count, tokens[p] == .any {
        star = p
        mark = t
        p += 1
      } else if star >= 0 {
        p = star + 1
        mark += 1
        t = mark
      } else {
        return false
      }
    }
    while p < tokens.count, tokens[p] == .any { p += 1 }
    return p == tokens.count
  }
}

// MARK: - Dates

/// Proleptic Gregorian date arithmetic with Excel serial numbers (1 = 1900-01-01 for modern
/// dates; serials are counted from 1899-12-30).
enum SpreadsheetDate {
  static let epoch = days(year: 1899, month: 12, day: 30)

  /// Days since 1970-01-01.
  static func days(year: Int, month: Int, day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let shiftedMonth = (month + 9) % 12
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  static func civil(_ days: Int) -> (year: Int, month: Int, day: Int) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let dayOfEra = z - era * 146_097
    let yearOfEra =
      (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
  }

  static func iso(_ days: Int) -> String {
    let date = civil(days)
    return String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
  }

  /// Days since 1970 for `yyyy-mm-dd` or `yyyy/mm/dd` text, optionally followed by a time.
  static func parse(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.prefix { $0 != " " && $0 != "T" }
      .split(whereSeparator: { $0 == "-" || $0 == "/" })
    guard parts.count == 3, parts[0].count == 4, let year = Int(parts[0]),
      let month = Int(parts[1]), let day = Int(parts[2]), (1...12).contains(month), day >= 1
    else { return nil }
    let value = days(year: year, month: month, day: day)
    guard civil(value).day == day else { return nil }
    return value
  }
}

// MARK: - Extended functions

extension SpreadsheetEvaluator {
  /// A rectangular block of cells named by a range or single-cell reference argument.
  struct Grid {
    var top: Int
    var left: Int
    var rows: Int
    var columns: Int

    /// The tab the cells are on, when it isn't the evaluator's own.
    var source: SpreadsheetEvaluator? = nil

    var count: Int { rows * columns }
    var isVector: Bool { rows == 1 || columns == 1 }

    func resized(like other: Grid) -> Grid {
      Grid(top: top, left: left, rows: other.rows, columns: other.columns, source: source)
    }
  }

  private enum LookupMode {
    case exact(wildcards: Bool)
    case ascending
    case descending
    case nextSmaller
    case nextLarger
  }

  private enum Aggregate {
    case sum
    case average
  }

  fileprivate func grid(_ argument: FormulaExpression) throws -> Grid {
    switch argument {
    case .range(let a, let b):
      return Grid(
        top: min(a.row, b.row), left: min(a.column, b.column),
        rows: abs(a.row - b.row) + 1, columns: abs(a.column - b.column) + 1)
    case .ref(let address):
      return Grid(top: address.row, left: address.column, rows: 1, columns: 1)
    case .sheet(let name, let inner):
      guard let other = tab(name) else { throw CellError(code: "#REF!") }
      var grid = try other.grid(inner)
      grid.source = other
      return grid
    default:
      if case .error(let code) = evaluate(argument) { throw CellError(code: code) }
      throw CellError(code: "#VALUE!")
    }
  }

  private func cell(_ grid: Grid, _ row: Int, _ column: Int) -> CellValue {
    (grid.source ?? self).value(at: CellAddress(column: grid.left + column, row: grid.top + row))
  }

  /// The `index`-th cell of a grid in row-major order.
  private func item(_ grid: Grid, _ index: Int) -> CellValue {
    cell(grid, index / grid.columns, index % grid.columns)
  }

  /// How many leading rows/columns of the grids can hold data; the rest are all empty.
  private func scanned(_ grids: [Grid]) -> (rows: Int, columns: Int) {
    guard let first = grids.first else { return (0, 0) }
    let rows =
      grids.map { min(first.rows, max(0, ($0.source ?? self).extent.rows - $0.top)) }.max() ?? 0
    let columns =
      grids.map { min(first.columns, max(0, ($0.source ?? self).extent.columns - $0.left)) }
      .max() ?? 0
    return (rows, columns)
  }

  /// How many leading items of a vector can hold data.
  private func scannedCount(_ grid: Grid) -> Int {
    let used = scanned([grid])
    return grid.columns == 1 ? used.rows : used.columns
  }

  private func integer(_ value: Double) throws -> Int {
    guard value.isFinite, abs(value) < 1e15 else { throw CellError(code: "#NUM!") }
    return Int(value.rounded(.towardZero))
  }

  /// Positions (row, column) where every criterion holds, plus how many unscanned (all-empty)
  /// cells would also match.
  private func matches(
    _ conditions: [(grid: Grid, criterion: SpreadsheetCriterion)], alongside extra: [Grid] = []
  ) throws -> (positions: [(Int, Int)], blankMatches: Int) {
    guard let first = conditions.first?.grid else { throw CellError(code: "#VALUE!") }
    for condition in conditions
    where condition.grid.rows != first.rows || condition.grid.columns != first.columns {
      throw CellError(code: "#VALUE!")
    }
    let used = scanned(conditions.map(\.grid) + extra)
    var positions: [(Int, Int)] = []
    for row in 0..<used.rows {
      for column in 0..<used.columns
      where conditions.allSatisfy({ $0.criterion.matches(cell($0.grid, row, column)) }) {
        positions.append((row, column))
      }
    }
    let blank =
      conditions.allSatisfy { $0.criterion.matches(.empty) }
      ? first.count - used.rows * used.columns : 0
    return (positions, blank)
  }

  private func aggregate(_ kind: Aggregate, _ values: [CellValue]) throws -> CellValue {
    var total = 0.0
    var count = 0
    for value in values {
      switch value {
      case .error(let code): throw CellError(code: code)
      case .number(let number):
        total += number
        count += 1
      default: continue
      }
    }
    switch kind {
    case .sum: return .number(total)
    case .average:
      guard count > 0 else { throw CellError(code: "#DIV/0!") }
      return .number(total / Double(count))
    }
  }

  private func lookupEquals(_ cell: CellValue, _ key: CellValue, wildcards: Bool) -> Bool {
    switch (cell, key) {
    case (.number(let a), .number(let b)): a == b
    case (.bool(let a), .bool(let b)): a == b
    case (.text(let a), .text(let b)):
      wildcards && SpreadsheetCriterion.hasWildcards(b)
        ? SpreadsheetCriterion.wildcardMatch(b, a) : a.caseInsensitiveCompare(b) == .orderedSame
    default: false
    }
  }

  private func sameKind(_ a: CellValue, _ b: CellValue) -> Bool {
    switch (a, b) {
    case (.number, .number), (.text, .text), (.bool, .bool): true
    default: false
    }
  }

  /// Zero-based index of `key` among `count` values, or nil when not found.
  private func lookup(
    _ key: CellValue, count: Int, mode: LookupMode, at fetch: (Int) -> CellValue
  ) -> Int? {
    switch mode {
    case .exact(let wildcards):
      return (0..<count).first { lookupEquals(fetch($0), key, wildcards: wildcards) }
    case .ascending, .descending:
      let stop: ComparisonResult = {
        if case .ascending = mode { return .orderedDescending }
        return .orderedAscending
      }()
      var found: Int?
      for index in 0..<count {
        let value = fetch(index)
        guard sameKind(value, key) else { continue }
        if compare(value, key) == stop { break }
        found = index
      }
      return found
    case .nextSmaller, .nextLarger:
      // Next smaller wants the largest value below the key; next larger the smallest above it.
      var best: (index: Int, value: CellValue)?
      var wanted = ComparisonResult.orderedDescending
      if case .nextSmaller = mode { wanted = .orderedAscending }
      for index in 0..<count {
        let value = fetch(index)
        guard sameKind(value, key) else { continue }
        let order = compare(value, key)
        if order == .orderedSame { return index }
        if order == wanted, best.map({ compare($0.value, value) == wanted }) ?? true {
          best = (index, value)
        }
      }
      return best?.index
    }
  }

  private func flags(_ args: [FormulaExpression]) throws -> [Bool] {
    var flags: [Bool] = []
    for arg in args {
      let (items, isRange) = values(of: arg)
      for item in items {
        if isRange, case .text = item { continue }
        flags.append(try truth(item))
      }
    }
    guard !flags.isEmpty else { throw CellError(code: "#VALUE!") }
    return flags
  }

  /// Snaps values within floating-point noise of an integer, so `2.1 * 10` rounds up to 21.
  private func snapped(_ value: Double) -> Double {
    let nearest = value.rounded()
    return abs(value - nearest) < 1e-9 * max(1, abs(value)) ? nearest : value
  }

  private func dateDays(_ value: CellValue) throws -> Int {
    switch value {
    case .text(let text):
      if let days = SpreadsheetDate.parse(text) { return days }
      guard let number = CellValue.parseNumber(text) else { throw CellError(code: "#VALUE!") }
      return try dateDays(.number(number))
    case .number(let serial):
      guard serial >= 0 else { throw CellError(code: "#NUM!") }
      return try integer(serial.rounded(.down)) + SpreadsheetDate.epoch
    case .empty: return SpreadsheetDate.epoch
    case .error(let code): throw CellError(code: code)
    case .bool: throw CellError(code: "#VALUE!")
    }
  }

  func extendedCall(_ name: String, _ args: [FormulaExpression]) throws -> CellValue {
    func arity(_ range: ClosedRange<Int>) throws {
      guard range.contains(args.count) else { throw CellError(code: "#VALUE!") }
    }
    func scalar(_ index: Int) throws -> CellValue {
      let value = evaluate(args[index])
      if case .error(let code) = value { throw CellError(code: code) }
      return value
    }
    func number(_ index: Int) throws -> Double { try numeric(scalar(index)) }
    func string(_ index: Int) throws -> String { try text(scalar(index)) }
    func whole(_ index: Int) throws -> Int { try integer(number(index)) }
    func finite(_ value: Double) throws -> CellValue {
      guard value.isFinite else { throw CellError(code: "#NUM!") }
      return .number(value)
    }

    switch name {
    // MARK: Conditional
    case "SUMIF", "AVERAGEIF":
      try arity(2...3)
      let range = try grid(args[0])
      let criterion = SpreadsheetCriterion(try scalar(1))
      let target = (args.count > 2 ? try grid(args[2]) : range).resized(like: range)
      let found = try matches([(range, criterion)], alongside: [target])
      return try aggregate(
        name == "SUMIF" ? .sum : .average, found.positions.map { cell(target, $0.0, $0.1) })
    case "SUMIFS", "AVERAGEIFS":
      guard args.count >= 3, args.count % 2 == 1 else { throw CellError(code: "#VALUE!") }
      let target = try grid(args[0])
      var conditions: [(grid: Grid, criterion: SpreadsheetCriterion)] = []
      for index in stride(from: 1, to: args.count, by: 2) {
        conditions.append((try grid(args[index]), SpreadsheetCriterion(try scalar(index + 1))))
      }
      guard conditions[0].grid.rows == target.rows, conditions[0].grid.columns == target.columns
      else { throw CellError(code: "#VALUE!") }
      let found = try matches(conditions, alongside: [target])
      return try aggregate(
        name == "SUMIFS" ? .sum : .average, found.positions.map { cell(target, $0.0, $0.1) })
    case "COUNTIF", "COUNTIFS":
      guard args.count >= 2, args.count % 2 == 0, name == "COUNTIFS" || args.count == 2 else {
        throw CellError(code: "#VALUE!")
      }
      var conditions: [(grid: Grid, criterion: SpreadsheetCriterion)] = []
      for index in stride(from: 0, to: args.count, by: 2) {
        conditions.append((try grid(args[index]), SpreadsheetCriterion(try scalar(index + 1))))
      }
      let found = try matches(conditions)
      return .number(Double(found.positions.count + found.blankMatches))
    case "IFERROR", "IFNA":
      try arity(2...2)
      let value = evaluate(args[0])
      if case .error(let code) = value, name == "IFERROR" || code == "#N/A" {
        return evaluate(args[1])
      }
      return value
    case "IFS":
      guard !args.isEmpty, args.count % 2 == 0 else { throw CellError(code: "#VALUE!") }
      for index in stride(from: 0, to: args.count, by: 2) {
        if try truth(scalar(index)) { return evaluate(args[index + 1]) }
      }
      throw CellError(code: "#N/A")
    case "SWITCH":
      guard args.count >= 3 else { throw CellError(code: "#VALUE!") }
      let subject = try scalar(0)
      var index = 1
      while index + 1 < args.count {
        if compare(subject, try scalar(index)) == .orderedSame {
          return evaluate(args[index + 1])
        }
        index += 2
      }
      if index < args.count { return evaluate(args[index]) }
      throw CellError(code: "#N/A")

    // MARK: Lookup
    case "VLOOKUP", "HLOOKUP":
      try arity(3...4)
      let key = try scalar(0)
      let table = try grid(args[1])
      let offset = try whole(2)
      let vertical = name == "VLOOKUP"
      guard offset >= 1 else { throw CellError(code: "#VALUE!") }
      guard offset <= (vertical ? table.columns : table.rows) else {
        throw CellError(code: "#REF!")
      }
      let sorted = args.count > 3 ? try truth(scalar(3)) : true
      let used = scanned([table])
      let found = lookup(
        key, count: vertical ? used.rows : used.columns,
        mode: sorted ? .ascending : .exact(wildcards: true)
      ) { vertical ? cell(table, $0, 0) : cell(table, 0, $0) }
      guard let found else { throw CellError(code: "#N/A") }
      return vertical ? cell(table, found, offset - 1) : cell(table, offset - 1, found)
    case "MATCH":
      try arity(2...3)
      let key = try scalar(0)
      let vector = try grid(args[1])
      guard vector.isVector else { throw CellError(code: "#N/A") }
      let type = args.count > 2 ? try number(2) : 1
      let mode: LookupMode =
        type > 0 ? .ascending : type < 0 ? .descending : .exact(wildcards: true)
      let found = lookup(key, count: scannedCount(vector), mode: mode) { item(vector, $0) }
      guard let found else { throw CellError(code: "#N/A") }
      return .number(Double(found + 1))
    case "XLOOKUP":
      try arity(3...5)
      let key = try scalar(0)
      let keys = try grid(args[1])
      let results = try grid(args[2])
      guard keys.isVector else { throw CellError(code: "#VALUE!") }
      let vertical = keys.columns == 1
      guard vertical ? results.rows == keys.rows : results.columns == keys.columns else {
        throw CellError(code: "#VALUE!")
      }
      let mode: LookupMode
      switch args.count > 4 ? try whole(4) : 0 {
      case 0: mode = .exact(wildcards: false)
      case -1: mode = .nextSmaller
      case 1: mode = .nextLarger
      case 2: mode = .exact(wildcards: true)
      default: throw CellError(code: "#VALUE!")
      }
      let found = lookup(key, count: scannedCount(keys), mode: mode) { item(keys, $0) }
      guard let found else {
        if args.count > 3 { return evaluate(args[3]) }
        throw CellError(code: "#N/A")
      }
      return vertical ? cell(results, found, 0) : cell(results, 0, found)
    case "INDEX":
      try arity(2...3)
      let table = try grid(args[0])
      var row = try whole(1)
      var column = args.count > 2 ? try whole(2) : 1
      if args.count == 2, table.rows == 1, table.columns > 1 { (row, column) = (1, row) }
      guard row >= 0, column >= 0 else { throw CellError(code: "#VALUE!") }
      if row == 0 {
        guard table.rows == 1 else { throw CellError(code: "#VALUE!") }
        row = 1
      }
      if column == 0 {
        guard table.columns == 1 else { throw CellError(code: "#VALUE!") }
        column = 1
      }
      guard row <= table.rows, column <= table.columns else { throw CellError(code: "#REF!") }
      return cell(table, row - 1, column - 1)

    // MARK: Math and statistics
    case "MEDIAN":
      let sorted = try numbers(args).sorted()
      guard !sorted.isEmpty else { throw CellError(code: "#NUM!") }
      let middle = sorted.count / 2
      return .number(
        sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle])
    case "MODE":
      let all = try numbers(args)
      var counts: [Double: Int] = [:]
      for value in all { counts[value, default: 0] += 1 }
      let top = counts.values.max() ?? 0
      guard top > 1, let mode = all.first(where: { counts[$0] == top }) else {
        throw CellError(code: "#N/A")
      }
      return .number(mode)
    case "PRODUCT":
      let all = try numbers(args)
      return try finite(all.isEmpty ? 0 : all.reduce(1, *))
    case "SUMPRODUCT":
      guard !args.isEmpty else { throw CellError(code: "#VALUE!") }
      let grids = try args.map(grid)
      guard grids.allSatisfy({ $0.rows == grids[0].rows && $0.columns == grids[0].columns }) else {
        throw CellError(code: "#VALUE!")
      }
      let used = scanned(grids)
      var total = 0.0
      for row in 0..<used.rows {
        for column in 0..<used.columns {
          var product = 1.0
          for grid in grids {
            switch cell(grid, row, column) {
            case .error(let code): throw CellError(code: code)
            case .number(let number): product *= number
            default: product = 0
            }
          }
          total += product
        }
      }
      return try finite(total)
    case "ROUNDUP", "ROUNDDOWN":
      try arity(1...2)
      let value = try number(0)
      let factor = pow(10, args.count > 1 ? try number(1).rounded(.towardZero) : 0)
      let scaled = snapped(abs(value) * factor)
      let rounded = (name == "ROUNDUP" ? scaled.rounded(.up) : scaled.rounded(.down)) / factor
      return .number(rounded.isFinite ? (value < 0 ? -rounded : rounded) : value)
    case "INT":
      try arity(1...1)
      return .number(try number(0).rounded(.down))
    case "MOD":
      try arity(2...2)
      let dividend = try number(0)
      let divisor = try number(1)
      guard divisor != 0 else { throw CellError(code: "#DIV/0!") }
      let quotient = snapped(dividend / divisor).rounded(.down)
      return try finite(dividend - divisor * quotient)
    case "POWER":
      try arity(2...2)
      let base = try number(0)
      let exponent = try number(1)
      guard !(base == 0 && exponent < 0) else { throw CellError(code: "#DIV/0!") }
      return try finite(pow(base, exponent))
    case "SQRT":
      try arity(1...1)
      let value = try number(0)
      guard value >= 0 else { throw CellError(code: "#NUM!") }
      return .number(value.squareRoot())
    case "EXP":
      try arity(1...1)
      return try finite(Foundation.exp(try number(0)))
    case "LN", "LOG10":
      try arity(1...1)
      let value = try number(0)
      guard value > 0 else { throw CellError(code: "#NUM!") }
      return .number(name == "LN" ? Foundation.log(value) : Foundation.log10(value))
    case "PI":
      try arity(0...0)
      return .number(Double.pi)
    case "RAND":
      try arity(0...0)
      return .number(Double.random(in: 0..<1))
    case "RANDBETWEEN":
      try arity(2...2)
      let low = try integer(number(0).rounded(.up))
      let high = try integer(number(1).rounded(.down))
      guard low <= high else { throw CellError(code: "#NUM!") }
      return .number(Double(Int.random(in: low...high)))
    case "CEILING", "FLOOR":
      try arity(1...2)
      let value = try number(0)
      let significance = args.count > 1 ? try number(1) : 1
      if significance == 0 {
        if name == "CEILING" { return .number(0) }
        throw CellError(code: "#DIV/0!")
      }
      guard !(value > 0 && significance < 0) else { throw CellError(code: "#NUM!") }
      let quotient = snapped(value / significance)
      return try finite(
        (name == "CEILING" ? quotient.rounded(.up) : quotient.rounded(.down)) * significance)
    case "STDEV", "VAR":
      let all = try numbers(args)
      guard all.count > 1 else { throw CellError(code: "#DIV/0!") }
      let mean = all.reduce(0, +) / Double(all.count)
      let variance =
        all.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(all.count - 1)
      return .number(name == "VAR" ? variance : variance.squareRoot())
    case "LARGE", "SMALL":
      try arity(2...2)
      let sorted = try numbers([args[0]]).sorted { name == "LARGE" ? $0 > $1 : $0 < $1 }
      let k = try integer(number(1).rounded(.up))
      guard k >= 1, k <= sorted.count else { throw CellError(code: "#NUM!") }
      return .number(sorted[k - 1])
    case "RANK":
      try arity(2...3)
      let value = try number(0)
      let all = try numbers([args[1]])
      guard all.contains(value) else { throw CellError(code: "#N/A") }
      let ascending = args.count > 2 ? try number(2) != 0 : false
      return .number(Double(1 + all.filter { ascending ? $0 < value : $0 > value }.count))
    case "COUNTBLANK":
      try arity(1...1)
      let range = try grid(args[0])
      let used = scanned([range])
      var blanks = range.count - used.rows * used.columns
      for row in 0..<used.rows {
        for column in 0..<used.columns {
          let value = cell(range, row, column)
          if value == .empty || value == .text("") { blanks += 1 }
        }
      }
      return .number(Double(blanks))

    // MARK: Text
    case "LEFT", "RIGHT":
      try arity(1...2)
      let source = try string(0)
      let count = args.count > 1 ? try whole(1) : 1
      guard count >= 0 else { throw CellError(code: "#VALUE!") }
      return .text(String(name == "LEFT" ? source.prefix(count) : source.suffix(count)))
    case "MID":
      try arity(3...3)
      let source = try string(0)
      let start = try whole(1)
      let count = try whole(2)
      guard start >= 1, count >= 0 else { throw CellError(code: "#VALUE!") }
      return .text(String(source.dropFirst(start - 1).prefix(count)))
    case "TRIM":
      try arity(1...1)
      return .text(try string(0).split(separator: " ").joined(separator: " "))
    case "SUBSTITUTE":
      try arity(3...4)
      let source = try string(0)
      let old = try string(1)
      let new = try string(2)
      guard !old.isEmpty else { return .text(source) }
      guard args.count > 3 else { return .text(source.replacingOccurrences(of: old, with: new)) }
      let occurrence = try whole(3)
      guard occurrence >= 1 else { throw CellError(code: "#VALUE!") }
      var searchStart = source.startIndex
      var seen = 0
      while let found = source.range(
        of: old, options: .literal, range: searchStart..<source.endIndex)
      {
        seen += 1
        if seen == occurrence { return .text(source.replacingCharacters(in: found, with: new)) }
        searchStart = found.upperBound
      }
      return .text(source)
    case "REPLACE":
      try arity(4...4)
      let source = try string(0)
      let start = try whole(1)
      let count = try whole(2)
      guard start >= 1, count >= 0 else { throw CellError(code: "#VALUE!") }
      return .text(
        String(source.prefix(start - 1)) + (try string(3))
          + String(source.dropFirst(start - 1 + count)))
    case "FIND", "SEARCH":
      try arity(2...3)
      let needle = try string(0)
      let haystack = try string(1)
      let start = args.count > 2 ? try whole(2) : 1
      let characters = Array(name == "FIND" ? haystack : haystack.lowercased())
      guard start >= 1, start <= characters.count + 1 else { throw CellError(code: "#VALUE!") }
      if name == "SEARCH", SpreadsheetCriterion.hasWildcards(needle) {
        for index in (start - 1)...characters.count
        where SpreadsheetCriterion.wildcardMatch(needle + "*", String(characters[index...])) {
          return .number(Double(index + 1))
        }
        throw CellError(code: "#VALUE!")
      }
      let pattern = Array(name == "FIND" ? needle : needle.lowercased())
      // A start is in range while a match can still begin at it: at most `count - needle`, and
      // an empty needle matches at its start position. The guard above admits `count + 1`, so
      // starting just past the end with a multi-character needle — FIND("World", "Hello World",
      // 8) — left the scan range inverted and trapped the process instead of answering
      // #VALUE!, as Excel does.
      let lastStart = pattern.count == 0 ? characters.count : characters.count - pattern.count
      if start - 1 <= lastStart {
        for index in (start - 1)...lastStart
        where characters[index..<index + pattern.count].elementsEqual(pattern) {
          return .number(Double(index + 1))
        }
      }
      throw CellError(code: "#VALUE!")
    case "PROPER":
      try arity(1...1)
      var previousIsLetter = false
      var output = ""
      for character in try string(0) {
        output += previousIsLetter ? character.lowercased() : character.uppercased()
        previousIsLetter = character.isLetter
      }
      return .text(output)
    case "REPT":
      try arity(2...2)
      let source = try string(0)
      let times = try whole(1)
      guard times >= 0, source.count * times <= 32_767 else { throw CellError(code: "#VALUE!") }
      return .text(String(repeating: source, count: times))
    case "TEXTJOIN":
      guard args.count >= 3 else { throw CellError(code: "#VALUE!") }
      let delimiter = try string(0)
      let ignoreEmpty = try truth(scalar(1))
      var parts: [String] = []
      for arg in args.dropFirst(2) {
        var items: [CellValue]
        if arg.isRange, !ignoreEmpty {
          let range = try grid(arg)
          guard range.count <= 100_000 else { throw CellError(code: "#VALUE!") }
          items = (0..<range.count).map { item(range, $0) }
        } else {
          items = values(of: arg).values
        }
        for value in items {
          let piece = try text(value)
          if ignoreEmpty, piece.isEmpty { continue }
          parts.append(piece)
        }
      }
      let joined = parts.joined(separator: delimiter)
      guard joined.count <= 32_767 else { throw CellError(code: "#VALUE!") }
      return .text(joined)
    case "VALUE":
      try arity(1...1)
      switch try scalar(0) {
      case .number(let number): return .number(number)
      case .empty: return .number(0)
      case .text(let text):
        if let number = CellValue.parseNumber(text) { return .number(number) }
        if let days = SpreadsheetDate.parse(text) {
          return .number(Double(days - SpreadsheetDate.epoch))
        }
        throw CellError(code: "#VALUE!")
      default: throw CellError(code: "#VALUE!")
      }
    case "TEXT":
      try arity(2...2)
      return .text(try format(try scalar(0), try string(1)))

    // MARK: Dates
    case "NOW":
      try arity(0...0)
      let parts = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute], from: Date())
      return .text(
        String(
          format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
          parts.hour ?? 0, parts.minute ?? 0))
    case "DATE":
      try arity(3...3)
      var year = try whole(0)
      let month = try whole(1)
      let day = try whole(2)
      guard (0..<10_000).contains(year), abs(month) < 120_000, abs(day) < 4_000_000 else {
        throw CellError(code: "#NUM!")
      }
      if year < 1900 { year += 1900 }
      let monthIndex = month - 1
      let carry = monthIndex >= 0 ? monthIndex / 12 : (monthIndex - 11) / 12
      let days =
        SpreadsheetDate.days(year: year + carry, month: monthIndex - carry * 12 + 1, day: 1) + day
        - 1
      guard (1900...9999).contains(SpreadsheetDate.civil(days).year) else {
        throw CellError(code: "#NUM!")
      }
      return .text(SpreadsheetDate.iso(days))
    case "YEAR", "MONTH", "DAY":
      try arity(1...1)
      let date = SpreadsheetDate.civil(try dateDays(scalar(0)))
      return .number(Double(name == "YEAR" ? date.year : name == "MONTH" ? date.month : date.day))
    case "DAYS":
      try arity(2...2)
      return .number(Double(try dateDays(scalar(0)) - dateDays(scalar(1))))

    // MARK: Logic and information
    case "XOR":
      return .bool(!(try flags(args).filter { $0 }.count).isMultiple(of: 2))
    case "ISBLANK", "ISNUMBER", "ISTEXT", "ISERROR":
      try arity(1...1)
      let value = evaluate(args[0])
      switch (name, value) {
      case ("ISBLANK", .empty), ("ISNUMBER", .number), ("ISTEXT", .text), ("ISERROR", .error):
        return .bool(true)
      default:
        return .bool(false)
      }
    default:
      throw CellError(code: "#NAME?")
    }
  }

  // MARK: TEXT formats

  private func format(_ value: CellValue, _ pattern: String) throws -> String {
    let lower = pattern.lowercased()
    if lower.isEmpty { return "" }
    if lower == "general" || lower == "@" { return value.display }
    if !lower.contains(where: { "0#".contains($0) }), lower.contains(where: { "ymd".contains($0) })
    {
      if case .text(let text) = value, SpreadsheetDate.parse(text) == nil,
        CellValue.parseNumber(text) == nil
      {
        return text
      }
      return formatDate(try dateDays(value), lower)
    }
    let number: Double
    switch value {
    case .number(let raw): number = raw
    case .empty: number = 0
    case .text(let text):
      guard let parsed = CellValue.parseNumber(text) else { return text }
      number = parsed
    case .bool, .error: return value.display
    }
    return formatNumber(number, pattern)
  }

  private func formatDate(_ days: Int, _ pattern: String) -> String {
    let date = SpreadsheetDate.civil(days)
    let weekday = ((days + 4) % 7 + 7) % 7
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let characters = Array(pattern)
    var output = ""
    var index = 0
    while index < characters.count {
      let character = characters[index]
      var run = 1
      while index + run < characters.count, characters[index + run] == character { run += 1 }
      switch character {
      case "y":
        output +=
          run >= 3 ? String(format: "%04d", date.year) : String(format: "%02d", date.year % 100)
      case "m":
        switch run {
        case 1: output += String(date.month)
        case 2: output += String(format: "%02d", date.month)
        case 3: output += formatter.shortMonthSymbols[date.month - 1]
        default: output += formatter.monthSymbols[date.month - 1]
        }
      case "d":
        switch run {
        case 1: output += String(date.day)
        case 2: output += String(format: "%02d", date.day)
        case 3: output += formatter.shortWeekdaySymbols[weekday]
        default: output += formatter.weekdaySymbols[weekday]
        }
      default:
        output += String(repeating: character, count: run)
      }
      index += run
    }
    return output
  }

  private func formatNumber(_ value: Double, _ pattern: String) -> String {
    let characters = Array(pattern)
    guard let coreStart = characters.firstIndex(where: { "0#.".contains($0) }) else {
      return pattern
    }
    var coreEnd = coreStart
    while coreEnd < characters.count, "0#.,".contains(characters[coreEnd]) { coreEnd += 1 }
    let prefix = String(characters[..<coreStart])
    let suffix = String(characters[coreEnd...])
    let core = characters[coreStart..<coreEnd]
    let integerPattern = core.prefix { $0 != "." }
    let fractionPattern = core.drop { $0 != "." }.dropFirst().filter { $0 != "," }
    let grouping = integerPattern.contains(",")
    let minimumIntegers = integerPattern.filter { $0 == "0" }.count
    let minimumFraction = fractionPattern.filter { $0 == "0" }.count
    let maximumFraction = fractionPattern.count
    let scaled = (prefix + suffix).contains("%") ? value * 100 : value
    let factor = pow(10, Double(maximumFraction))
    let rounded = (abs(scaled) * factor).rounded(.toNearestOrAwayFromZero) / factor
    let fixed = String(format: "%.\(maximumFraction)f", rounded)
    let pieces = fixed.split(separator: ".", omittingEmptySubsequences: false)
    var integerDigits = String(pieces[0])
    if integerDigits == "0", minimumIntegers == 0 { integerDigits = "" }
    if integerDigits.count < minimumIntegers {
      integerDigits =
        String(repeating: "0", count: minimumIntegers - integerDigits.count)
        + integerDigits
    }
    if grouping {
      var grouped = ""
      for (offset, digit) in integerDigits.enumerated() {
        if offset > 0, (integerDigits.count - offset) % 3 == 0 { grouped += "," }
        grouped.append(digit)
      }
      integerDigits = grouped
    }
    var fraction = pieces.count > 1 ? String(pieces[1]) : ""
    while fraction.count > minimumFraction, fraction.hasSuffix("0") { fraction.removeLast() }
    let sign = scaled < 0 && rounded != 0 ? "-" : ""
    return sign + prefix + integerDigits + (fraction.isEmpty ? "" : "." + fraction) + suffix
  }
}
