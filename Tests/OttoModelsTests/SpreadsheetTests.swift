import Foundation
import Testing

@testable import OttoModels

@Suite("Spreadsheet")
struct SpreadsheetTests {
  @Test("Addresses parse A1 notation and column names round trip")
  func addresses() {
    #expect(CellAddress.columnName(0) == "A")
    #expect(CellAddress.columnName(25) == "Z")
    #expect(CellAddress.columnName(26) == "AA")
    #expect(CellAddress.columnName(701) == "ZZ")
    #expect(CellAddress.columnName(702) == "AAA")
    #expect(CellAddress("A1") == CellAddress(column: 0, row: 0))
    #expect(CellAddress("b12") == CellAddress(column: 1, row: 11))
    #expect(CellAddress("AA3") == CellAddress(column: 26, row: 2))
    #expect(CellAddress("$C$4") == CellAddress(column: 2, row: 3))
    #expect(CellAddress("A0") == nil)
    #expect(CellAddress("1A") == nil)
    #expect(CellAddress("A") == nil)
    #expect(CellAddress("A1B") == nil)
    #expect(CellAddress("") == nil)
    #expect(CellAddress(column: 27, row: 9).a1 == "AB10")
    #expect(CellAddress("B1")! < CellAddress("A2")!)
  }

  @Test("Sheet keys normalise and empty input clears cells")
  func sheetStorage() {
    var sheet = Spreadsheet()
    #expect(sheet.usedSize == (0, 0))
    sheet.set("$b$2", "Hello")
    sheet.set("d1", "4")
    #expect(sheet.cells == ["B2": "Hello", "D1": "4"])
    #expect(sheet.raw("b2") == "Hello")
    #expect(sheet.raw("Z9") == "")
    #expect(sheet.usedSize == (4, 2))
    sheet.set("D1", "")
    #expect(sheet.cells == ["B2": "Hello"])
    #expect(sheet.usedSize == (2, 2))
  }

  @Test("Raw input parses into numbers, booleans and text")
  func rawParsing() {
    let sheet = Spreadsheet(cells: [
      "A1": "12", "A2": "1,234.5", "A3": "12%", "A4": "$5", "A5": "-3.25",
      "A6": "true", "A7": "Hello", "A8": "1,2", "A9": " 7 ",
    ])
    let evaluator = SpreadsheetEvaluator(sheet)
    #expect(evaluator.value(at: "A1") == .number(12))
    #expect(evaluator.value(at: "A2") == .number(1234.5))
    #expect(evaluator.value(at: "A3") == .number(0.12))
    #expect(evaluator.value(at: "A4") == .number(5))
    #expect(evaluator.value(at: "A5") == .number(-3.25))
    #expect(evaluator.value(at: "A6") == .bool(true))
    #expect(evaluator.value(at: "A7") == .text("Hello"))
    #expect(evaluator.value(at: "A8") == .text("1,2"))
    #expect(evaluator.value(at: "A9") == .number(7))
    #expect(evaluator.value(at: "B1") == .empty)
  }

  @Test("Display formats integers, fractions, booleans and errors")
  func display() {
    #expect(CellValue.number(3).display == "3")
    #expect(CellValue.number(-0.0).display == "0")
    #expect(CellValue.number(0.1 + 0.2).display == "0.3")
    #expect(CellValue.number(1.0 / 3).display == "0.3333333333")
    #expect(CellValue.bool(false).display == "FALSE")
    #expect(CellValue.error("#DIV/0!").display == "#DIV/0!")
    #expect(CellValue.empty.display == "")
    #expect(CellValue.text("2.5").number == 2.5)
    #expect(CellValue.text("x").number == nil)
    #expect(CellValue.bool(true).number == 1)
    #expect(CellValue.empty.number == nil)
  }

  @Test("Arithmetic follows operator precedence")
  func arithmetic() {
    let evaluator = SpreadsheetEvaluator(Spreadsheet(cells: ["A1": "2", "A2": "3"]))
    #expect(evaluator.evaluate(formula: "=1+2*3") == .number(7))
    #expect(evaluator.evaluate(formula: "(1+2)*3") == .number(9))
    #expect(evaluator.evaluate(formula: "2^3^2") == .number(512))
    #expect(evaluator.evaluate(formula: "-A1^2") == .number(4))
    #expect(evaluator.evaluate(formula: "10-4-3") == .number(3))
    #expect(evaluator.evaluate(formula: "8/4/2") == .number(1))
    #expect(evaluator.evaluate(formula: "=a1*$A$2 + 1") == .number(7))
    #expect(evaluator.evaluate(formula: "A1+B9") == .number(2))
    #expect(evaluator.evaluate(formula: "B9") == .number(0))
    #expect(evaluator.evaluate(formula: "1.5e2") == .number(150))
  }

  @Test("Functions aggregate over ranges")
  func functions() {
    let sheet = Spreadsheet(cells: [
      "A1": "1", "A2": "2", "A3": "3", "A4": "text", "B1": "10", "B2": "=A1+A2",
    ])
    let evaluator = SpreadsheetEvaluator(sheet)
    #expect(evaluator.evaluate(formula: "SUM(A1:A4)") == .number(6))
    #expect(evaluator.evaluate(formula: "sum(A1:B2, 4)") == .number(20))
    #expect(evaluator.evaluate(formula: "AVERAGE(A1:A3)") == .number(2))
    #expect(evaluator.evaluate(formula: "MIN(A1:B2)") == .number(1))
    #expect(evaluator.evaluate(formula: "MAX(B1:A3)") == .number(10))
    #expect(evaluator.evaluate(formula: "COUNT(A1:A4)") == .number(3))
    #expect(evaluator.evaluate(formula: "COUNTA(A1:A9)") == .number(4))
    #expect(evaluator.evaluate(formula: "ROUND(2.345, 2)") == .number(2.35))
    #expect(evaluator.evaluate(formula: "ROUND(-2.5)") == .number(-3))
    #expect(evaluator.evaluate(formula: "ROUND(1234, -2)") == .number(1200))
    #expect(evaluator.evaluate(formula: "ABS(-4)") == .number(4))
    #expect(evaluator.evaluate(formula: "LEN(\"hello\")") == .number(5))
    #expect(evaluator.evaluate(formula: "UPPER(A4)") == .text("TEXT"))
    #expect(evaluator.evaluate(formula: "LOWER(\"MiX\")") == .text("mix"))
    #expect(evaluator.evaluate(formula: "AVERAGE(C1:C3)") == .error("#DIV/0!"))
    if case .text(let today) = evaluator.evaluate(formula: "TODAY()") {
      #expect(today.count == 10)
    } else {
      Issue.record("TODAY() should return ISO date text")
    }
  }

  @Test("IF, logic and comparisons return booleans")
  func logic() {
    let evaluator = SpreadsheetEvaluator(Spreadsheet(cells: ["A1": "5", "A2": "abc"]))
    #expect(evaluator.evaluate(formula: "IF(A1>3, \"big\", \"small\")") == .text("big"))
    #expect(evaluator.evaluate(formula: "IF(A1<3, 1)") == .bool(false))
    #expect(evaluator.evaluate(formula: "IF(TRUE, 1, 1/0)") == .number(1))
    #expect(evaluator.evaluate(formula: "A1>=5") == .bool(true))
    #expect(evaluator.evaluate(formula: "A1<>5") == .bool(false))
    #expect(evaluator.evaluate(formula: "A2=\"ABC\"") == .bool(true))
    #expect(evaluator.evaluate(formula: "1<\"a\"") == .bool(true))
    #expect(evaluator.evaluate(formula: "1+1=2") == .bool(true))
    #expect(evaluator.evaluate(formula: "AND(TRUE, A1>1)") == .bool(true))
    #expect(evaluator.evaluate(formula: "OR(FALSE, 0)") == .bool(false))
    #expect(evaluator.evaluate(formula: "NOT(A1=5)") == .bool(false))
  }

  @Test("Concatenation joins display text")
  func concatenation() {
    let evaluator = SpreadsheetEvaluator(
      Spreadsheet(cells: ["A1": "Total", "A2": "3", "A3": "TRUE"]))
    #expect(evaluator.evaluate(formula: "A1&\": \"&A2*2") == .text("Total: 6"))
    #expect(evaluator.evaluate(formula: "CONCAT(A1:A3)") == .text("Total3TRUE"))
    #expect(
      evaluator.evaluate(formula: "CONCATENATE(\"a\", 1.5, \"\"\"q\"\"\")") == .text("a1.5\"q\""))
  }

  @Test("Errors surface and propagate")
  func errors() {
    let sheet = Spreadsheet(cells: [
      "A1": "=1/0", "A2": "=A1+1", "B1": "=B2", "B2": "=B1", "C1": "=C1+1", "D1": "word",
      "E1": "=SUM(A1:A2)",
    ])
    let evaluator = SpreadsheetEvaluator(sheet)
    #expect(evaluator.value(at: "A1") == .error("#DIV/0!"))
    #expect(evaluator.value(at: "A2") == .error("#DIV/0!"))
    #expect(evaluator.value(at: "E1") == .error("#DIV/0!"))
    #expect(evaluator.value(at: "B1") == .error("#CYCLE!"))
    #expect(evaluator.value(at: "B2") == .error("#CYCLE!"))
    #expect(evaluator.value(at: "C1") == .error("#CYCLE!"))
    #expect(evaluator.evaluate(formula: "NOPE(1)") == .error("#NAME?"))
    #expect(evaluator.evaluate(formula: "D1*2") == .error("#VALUE!"))
    #expect(evaluator.evaluate(formula: "A0+1") == .error("#REF!"))
    #expect(evaluator.evaluate(formula: "1+") == .error("#ERROR!"))
    #expect(evaluator.evaluate(formula: "(1") == .error("#ERROR!"))
    #expect(evaluator.evaluate(formula: "\"open") == .error("#ERROR!"))
    #expect(evaluator.evaluate(formula: "=") == .error("#ERROR!"))
    #expect(evaluator.evaluate(formula: "A1:A2") == .error("#VALUE!"))
    #expect(evaluator.value(at: "nope") == .error("#REF!"))
  }

  @Test("CSV round trips quotes, commas and embedded newlines")
  func csvRoundTrip() {
    var sheet = Spreadsheet()
    sheet.set("A1", "Name")
    sheet.set("B1", "Note")
    sheet.set("A2", "Smith, Jo")
    sheet.set("B2", "said \"hi\"\nthen left")
    sheet.set("C3", "=SUM(1,2)")
    let raw = SpreadsheetCSV.encode(sheet, evaluated: false)
    #expect(
      raw == "Name,Note,\r\n\"Smith, Jo\",\"said \"\"hi\"\"\nthen left\",\r\n,,\"=SUM(1,2)\"")
    #expect(SpreadsheetCSV.decode(raw) == sheet)
    #expect(SpreadsheetCSV.encode(sheet, evaluated: true).hasSuffix(",,3"))
    #expect(SpreadsheetCSV.encode(Spreadsheet(), evaluated: true) == "")

    let decoded = SpreadsheetCSV.decode("\u{FEFF}a,b\r\n1,\"x\r\ny\"\n")
    #expect(decoded.cells == ["A1": "a", "B1": "b", "A2": "1", "B2": "x\r\ny"])
  }

  @Test("Zip archives pass unzip -t")
  func zipArchive() throws {
    #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    let archive = ZipArchive.make(entries: [
      ("hello.txt", Data("Hello, world\n".utf8)),
      ("nested/dir/data.bin", Data((0..<1000).map { UInt8($0 % 251) })),
      ("empty.txt", Data()),
    ])
    let url = try temporaryFile(archive, extension: "zip")
    defer { try? FileManager.default.removeItem(at: url) }
    let result = try run("/usr/bin/unzip", ["-t", url.path])
    #expect(result.status == 0)
    #expect(result.output.contains("No errors detected"))
  }

  @Test("XLSX keeps formulas and typed values")
  func xlsx() throws {
    var sheet = Spreadsheet(columnWidths: [1: 120])
    sheet.set("A1", "1")
    sheet.set("A2", "2")
    sheet.set("A3", "=SUM(A1:A2)")
    sheet.set("B1", "Fish & <Chips>")
    sheet.set("B2", "TRUE")
    sheet.set("B3", "=concat(\"a\", \"b\")")
    let data = XLSXWriter.data(for: sheet, sheetName: "Q3: [Plan]/Budget")
    let url = try temporaryFile(data, extension: "xlsx")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try run("/usr/bin/unzip", ["-t", url.path]).status == 0)
    let xml = try run("/usr/bin/unzip", ["-p", url.path, "xl/worksheets/sheet1.xml"]).output
    #expect(xml.contains(#"<c r="A3"><f>SUM(A1:A2)</f><v>3</v></c>"#))
    #expect(xml.contains(#"<c r="A1"><v>1</v></c>"#))
    #expect(xml.contains("<t>Fish &amp; &lt;Chips&gt;</t>"))
    #expect(xml.contains(#"<c r="B2" t="b"><v>1</v></c>"#))
    #expect(xml.contains("<f>_xlfn.CONCAT(&quot;a&quot;, &quot;b&quot;)</f>"))
    #expect(xml.contains(#"<col min="2" max="2""#))
    let workbook = try run("/usr/bin/unzip", ["-p", url.path, "xl/workbook.xml"]).output
    #expect(workbook.contains(#"name="Q3 PlanBudget""#))
    #expect(XLSXWriter.sanitizedSheetName("  ") == "Sheet1")
    #expect(XLSXWriter.sanitizedSheetName(String(repeating: "x", count: 40)).count == 31)
  }

  // MARK: Extended functions

  /// Region / product / units / price table in A1:D6 with a header row.
  private var salesSheet: Spreadsheet {
    Spreadsheet(cells: [
      "A1": "Region", "B1": "Product", "C1": "Units", "D1": "Price",
      "A2": "North", "B2": "Apple", "C2": "10", "D2": "1.5",
      "A3": "South", "B3": "Banana", "C3": "5", "D3": "0.25",
      "A4": "North", "B4": "Cherry", "C4": "20", "D4": "4",
      "A5": "East", "B5": "apple", "C5": "8", "D5": "1.5",
      "A6": "North", "B6": "Date", "D6": "3",
    ])
  }

  @Test("Criteria compare numbers, text, blanks and wildcards")
  func criteria() {
    func matches(_ criterion: CellValue, _ cell: CellValue) -> Bool {
      SpreadsheetCriterion(criterion).matches(cell)
    }
    #expect(matches(.text(">5"), .number(6)))
    #expect(!matches(.text(">5"), .number(5)))
    #expect(matches(.text(">=5"), .number(5)))
    #expect(matches(.text("<5"), .number(4.5)))
    #expect(matches(.text("<=5"), .number(5)))
    #expect(!matches(.text(">5"), .text("abc")))
    #expect(matches(.text("<>x"), .text("y")))
    #expect(matches(.text("<>x"), .empty))
    #expect(!matches(.text("<>X"), .text("x")))
    #expect(matches(.text("=apple"), .text("APPLE")))
    #expect(matches(.text("apple"), .text("Apple")))
    #expect(matches(.number(3), .number(3)))
    #expect(matches(.number(3), .text("3")))
    #expect(matches(.text("a*"), .text("Apple")))
    #expect(matches(.text("*an*"), .text("banana")))
    #expect(matches(.text("?pple"), .text("apple")))
    #expect(!matches(.text("?pple"), .text("aapple")))
    #expect(matches(.text("~*"), .text("*")))
    #expect(!matches(.text("~*"), .text("x")))
    #expect(matches(.text(""), .empty))
    #expect(matches(.text("="), .text("")))
    #expect(matches(.text("<>"), .number(1)))
    #expect(!matches(.text("<>"), .empty))
    #expect(matches(.text("TRUE"), .bool(true)))
    #expect(matches(.text(">b"), .text("Cherry")))
  }

  @Test("Conditional aggregates follow Excel semantics")
  func conditionalAggregates() {
    let evaluator = SpreadsheetEvaluator(salesSheet)
    #expect(evaluator.evaluate(formula: "SUMIF(A2:A6, \"North\", C2:C6)") == .number(30))
    #expect(evaluator.evaluate(formula: "sumif(C2:C6, \">=8\")") == .number(38))
    #expect(evaluator.evaluate(formula: "SUMIF(B2:B6, \"a*\", D2:D6)") == .number(3))
    #expect(evaluator.evaluate(formula: "SUMIF(A2:A6, \"North\", D2)") == .number(8.5))
    #expect(
      evaluator.evaluate(formula: "SUMIFS(C2:C6, A2:A6, \"North\", C2:C6, \">10\")") == .number(20))
    #expect(
      evaluator.evaluate(formula: "SUMIFS(C2:C6, A2:A6, \"North\", B2:B3, \"x\")")
        == .error("#VALUE!"))
    #expect(evaluator.evaluate(formula: "COUNTIF(A2:A6, \"north\")") == .number(3))
    #expect(evaluator.evaluate(formula: "COUNTIF(C2:C6, \"\")") == .number(1))
    #expect(evaluator.evaluate(formula: "COUNTIF(C2:C20, \"\")") == .number(15))
    #expect(evaluator.evaluate(formula: "COUNTIF(A2:A6, \"<>North\")") == .number(2))
    #expect(evaluator.evaluate(formula: "COUNTIFS(A2:A6, \"North\", D2:D6, \">2\")") == .number(2))
    #expect(evaluator.evaluate(formula: "AVERAGEIF(A2:A6, \"North\", C2:C6)") == .number(15))
    #expect(evaluator.evaluate(formula: "AVERAGEIF(A2:A6, \"West\", C2:C6)") == .error("#DIV/0!"))
    #expect(
      evaluator.evaluate(formula: "AVERAGEIFS(D2:D6, A2:A6, \"North\", B2:B6, \"<>Date\")")
        == .number(2.75))
    #expect(evaluator.evaluate(formula: "COUNTIF(1, 1)") == .error("#VALUE!"))
  }

  @Test("IFERROR, IFNA, IFS and SWITCH choose values")
  func conditionalChoice() {
    let evaluator = SpreadsheetEvaluator(Spreadsheet(cells: ["A1": "2", "A2": "=1/0"]))
    #expect(evaluator.evaluate(formula: "IFERROR(1/0, \"none\")") == .text("none"))
    #expect(evaluator.evaluate(formula: "IFERROR(A1*2, 0)") == .number(4))
    #expect(evaluator.evaluate(formula: "IFERROR(A2, -1)") == .number(-1))
    #expect(
      evaluator.evaluate(formula: "IFNA(MATCH(9, A1:A1, 0), \"missing\")") == .text("missing"))
    #expect(evaluator.evaluate(formula: "IFNA(1/0, 0)") == .error("#DIV/0!"))
    #expect(
      evaluator.evaluate(formula: "IFS(A1>5, \"big\", A1>1, \"mid\", TRUE, \"small\")")
        == .text("mid"))
    #expect(evaluator.evaluate(formula: "IFS(A1>5, \"big\")") == .error("#N/A"))
    #expect(evaluator.evaluate(formula: "IFS(A1>5)") == .error("#VALUE!"))
    #expect(evaluator.evaluate(formula: "SWITCH(A1, 1, \"one\", 2, \"two\")") == .text("two"))
    #expect(evaluator.evaluate(formula: "SWITCH(\"B\", \"a\", 1, \"b\", 2)") == .number(2))
    #expect(evaluator.evaluate(formula: "SWITCH(A1, 1, \"one\", \"other\")") == .text("other"))
    #expect(evaluator.evaluate(formula: "SWITCH(A1, 1, \"one\")") == .error("#N/A"))
  }

  @Test("VLOOKUP and HLOOKUP support exact and approximate matches")
  func verticalAndHorizontalLookup() {
    var sheet = salesSheet
    // Sorted tax brackets in F1:G4 and a header row lookup in J1:L2.
    for (a1, raw) in [
      ("F1", "0"), ("G1", "0%"), ("F2", "1000"), ("G2", "10%"), ("F3", "5000"), ("G3", "20%"),
      ("F4", "10000"), ("G4", "30%"), ("J1", "Q1"), ("K1", "Q2"), ("L1", "Q3"), ("J2", "100"),
      ("K2", "200"), ("L2", "300"),
    ] {
      sheet.set(a1, raw)
    }
    let evaluator = SpreadsheetEvaluator(sheet)
    #expect(evaluator.evaluate(formula: "VLOOKUP(\"cherry\", B2:D6, 2, FALSE)") == .number(20))
    #expect(evaluator.evaluate(formula: "VLOOKUP(\"Ch*\", B2:D6, 3, 0)") == .number(4))
    #expect(evaluator.evaluate(formula: "VLOOKUP(\"Fig\", B2:D6, 2, FALSE)") == .error("#N/A"))
    #expect(evaluator.evaluate(formula: "VLOOKUP(\"Apple\", B2:D6, 4, FALSE)") == .error("#REF!"))
    #expect(evaluator.evaluate(formula: "VLOOKUP(\"Apple\", B2:D6, 0, FALSE)") == .error("#VALUE!"))
    #expect(evaluator.evaluate(formula: "VLOOKUP(7500, F1:G4, 2)") == .number(0.2))
    #expect(evaluator.evaluate(formula: "VLOOKUP(10000, F1:G4, 2, TRUE)") == .number(0.3))
    #expect(evaluator.evaluate(formula: "VLOOKUP(999, F1:G4, 2, TRUE)") == .number(0))
    #expect(evaluator.evaluate(formula: "VLOOKUP(-1, F1:G4, 2, TRUE)") == .error("#N/A"))
    #expect(evaluator.evaluate(formula: "VLOOKUP(\"Date\", B2:C6, 2, FALSE)") == .number(0))
    #expect(evaluator.evaluate(formula: "HLOOKUP(\"q2\", J1:L2, 2, FALSE)") == .number(200))
    #expect(evaluator.evaluate(formula: "HLOOKUP(\"Q4\", J1:L2, 2, FALSE)") == .error("#N/A"))
    #expect(evaluator.evaluate(formula: "HLOOKUP(\"Q1\", J1:L2, 3, FALSE)") == .error("#REF!"))
    #expect(
      evaluator.evaluate(formula: "VLOOKUP(\"Banana\", B2:D6, 3, FALSE)*2&\" each\"")
        == .text("0.5 each"))
  }

  @Test("XLOOKUP, INDEX and MATCH find positions and values")
  func xlookupIndexMatch() {
    var sheet = salesSheet
    for (a1, raw) in [("F1", "30"), ("F2", "20"), ("F3", "10")] { sheet.set(a1, raw) }
    let evaluator = SpreadsheetEvaluator(sheet)
    #expect(evaluator.evaluate(formula: "XLOOKUP(\"banana\", B2:B6, C2:C6)") == .number(5))
    #expect(evaluator.evaluate(formula: "XLOOKUP(\"Fig\", B2:B6, C2:C6)") == .error("#N/A"))
    #expect(
      evaluator.evaluate(formula: "XLOOKUP(\"Fig\", B2:B6, C2:C6, \"none\")") == .text("none"))
    #expect(evaluator.evaluate(formula: "XLOOKUP(\"B*\", B2:B6, A2:A6, \"\", 2)") == .text("South"))
    #expect(evaluator.evaluate(formula: "XLOOKUP(\"B*\", B2:B6, A2:A6, \"-\")") == .text("-"))
    #expect(evaluator.evaluate(formula: "XLOOKUP(9, C2:C6, B2:B6, \"\", -1)") == .text("apple"))
    #expect(evaluator.evaluate(formula: "XLOOKUP(9, C2:C6, B2:B6, \"\", 1)") == .text("Apple"))
    #expect(evaluator.evaluate(formula: "XLOOKUP(\"Price\", A1:D1, A3:D3)") == .number(0.25))
    #expect(evaluator.evaluate(formula: "XLOOKUP(1, B2:B6, C2:C5)") == .error("#VALUE!"))
    #expect(evaluator.evaluate(formula: "INDEX(A1:D6, 4, 2)") == .text("Cherry"))
    #expect(evaluator.evaluate(formula: "INDEX(B2:B6, 2)") == .text("Banana"))
    #expect(evaluator.evaluate(formula: "INDEX(A1:D1, 3)") == .text("Units"))
    #expect(evaluator.evaluate(formula: "INDEX(A1:D6, 7, 1)") == .error("#REF!"))
    #expect(evaluator.evaluate(formula: "INDEX(A1:D6, -1, 1)") == .error("#VALUE!"))
    #expect(evaluator.evaluate(formula: "MATCH(\"Cherry\", B1:B6, 0)") == .number(4))
    #expect(evaluator.evaluate(formula: "MATCH(\"d?te\", B1:B6, 0)") == .number(6))
    #expect(evaluator.evaluate(formula: "MATCH(\"Units\", A1:D1, 0)") == .number(3))
    #expect(evaluator.evaluate(formula: "MATCH(25, F3:F1, -1)") == .number(1))
    #expect(evaluator.evaluate(formula: "MATCH(15, F1:F3, -1)") == .number(2))
    #expect(evaluator.evaluate(formula: "MATCH(5, F1:F3, -1)") == .number(3))
    #expect(evaluator.evaluate(formula: "MATCH(35, F1:F3, -1)") == .error("#N/A"))
    #expect(evaluator.evaluate(formula: "MATCH(4, D2:D4, 0)") == .number(3))
    #expect(evaluator.evaluate(formula: "MATCH(1, A1:D6, 0)") == .error("#N/A"))
    #expect(
      evaluator.evaluate(formula: "INDEX(C1:C6, MATCH(\"Cherry\", B1:B6, 0))") == .number(20))
  }

  @Test("Approximate MATCH assumes ascending order")
  func approximateMatch() {
    let evaluator = SpreadsheetEvaluator(
      Spreadsheet(cells: ["A1": "10", "A2": "20", "A3": "30", "B1": "a", "B2": "m", "B3": "t"]))
    #expect(evaluator.evaluate(formula: "MATCH(25, A1:A3)") == .number(2))
    #expect(evaluator.evaluate(formula: "MATCH(30, A1:A3, 1)") == .number(3))
    #expect(evaluator.evaluate(formula: "MATCH(99, A1:A3, 1)") == .number(3))
    #expect(evaluator.evaluate(formula: "MATCH(5, A1:A3, 1)") == .error("#N/A"))
    #expect(evaluator.evaluate(formula: "MATCH(\"p\", B1:B3, 1)") == .number(2))
  }

  @Test("Math and statistics functions")
  func mathAndStatistics() {
    let evaluator = SpreadsheetEvaluator(
      Spreadsheet(cells: [
        "A1": "2", "A2": "4", "A3": "4", "A4": "4", "A5": "5", "A6": "5", "A7": "7", "A8": "9",
        "B1": "1", "B2": "2", "B3": "3", "C1": "4", "C2": "5", "C3": "6", "D1": "x",
      ]))
    func value(_ formula: String) -> CellValue { evaluator.evaluate(formula: formula) }
    #expect(value("MEDIAN(A1:A8)") == .number(4.5))
    #expect(value("MEDIAN(3, 1, 2)") == .number(2))
    #expect(value("MEDIAN(E1:E2)") == .error("#NUM!"))
    #expect(value("MODE(A1:A8)") == .number(4))
    #expect(value("MODE(1, 2, 3)") == .error("#N/A"))
    #expect(value("PRODUCT(B1:B3, 2)") == .number(12))
    #expect(value("SUMPRODUCT(B1:B3, C1:C3)") == .number(32))
    #expect(value("SUMPRODUCT(B1:B3, C1:C2)") == .error("#VALUE!"))
    #expect(value("ROUNDUP(2.1, 0)") == .number(3))
    #expect(value("ROUNDUP(-2.11, 1)") == .number(-2.2))
    #expect(value("ROUNDUP(2.1, 1)") == .number(2.1))
    #expect(value("ROUNDDOWN(2.99)") == .number(2))
    #expect(value("ROUNDDOWN(0.29, 2)") == .number(0.29))
    #expect(value("ROUNDDOWN(-1.99, 1)") == .number(-1.9))
    #expect(value("INT(-2.5)") == .number(-3))
    #expect(value("INT(2.9)") == .number(2))
    #expect(value("MOD(10, 3)") == .number(1))
    #expect(value("MOD(-3, 2)") == .number(1))
    #expect(value("MOD(3, -2)") == .number(-1))
    #expect(value("MOD(1, 0)") == .error("#DIV/0!"))
    #expect(value("POWER(2, 10)") == .number(1024))
    #expect(value("POWER(0, -1)") == .error("#DIV/0!"))
    #expect(value("SQRT(16)") == .number(4))
    #expect(value("SQRT(-1)") == .error("#NUM!"))
    #expect(value("EXP(0)") == .number(1))
    #expect(value("ROUND(LN(EXP(2)), 10)") == .number(2))
    #expect(value("LN(0)") == .error("#NUM!"))
    #expect(value("LOG10(1000)") == .number(3))
    #expect(value("ROUND(PI(), 4)") == .number(3.1416))
    #expect(value("CEILING(2.1)") == .number(3))
    #expect(value("CEILING(4.2, 0.5)") == .number(4.5))
    #expect(value("CEILING(-2.5, 2)") == .number(-2))
    #expect(value("CEILING(2.5, -2)") == .error("#NUM!"))
    #expect(value("FLOOR(4.7, 2)") == .number(4))
    #expect(value("FLOOR(-2.5, -2)") == .number(-2))
    #expect(value("FLOOR(1, 0)") == .error("#DIV/0!"))
    #expect(value("VAR(B1:C3)") == .number(3.5))
    #expect(value("ROUND(STDEV(A1:A8), 6)") == .number(2.138090))
    #expect(value("STDEV(1)") == .error("#DIV/0!"))
    #expect(value("LARGE(A1:A8, 2)") == .number(7))
    #expect(value("SMALL(A1:A8, 1)") == .number(2))
    #expect(value("SMALL(A1:A8, 9)") == .error("#NUM!"))
    #expect(value("RANK(7, A1:A8)") == .number(2))
    #expect(value("RANK(4, A1:A8)") == .number(5))
    #expect(value("RANK(4, A1:A8, 1)") == .number(2))
    #expect(value("RANK(3, A1:A8)") == .error("#N/A"))
    #expect(value("COUNTBLANK(A1:E3)") == .number(5))
    #expect(value("COUNTBLANK(Z1:Z100)") == .number(100))
    let random = value("RAND()").number ?? -1
    #expect(random >= 0 && random < 1)
    for _ in 0..<20 {
      let integer = value("RANDBETWEEN(1, 3)").number ?? 0
      #expect([1, 2, 3].contains(integer))
    }
    #expect(value("RANDBETWEEN(5, 1)") == .error("#NUM!"))
  }

  @Test("Text functions slice, search and join")
  func textFunctions() {
    let evaluator = SpreadsheetEvaluator(
      Spreadsheet(cells: ["A1": "a", "A2": "", "A3": "c", "B1": "Hello World"]))
    func value(_ formula: String) -> CellValue { evaluator.evaluate(formula: formula) }
    #expect(value("LEFT(B1, 5)") == .text("Hello"))
    #expect(value("LEFT(B1)") == .text("H"))
    #expect(value("RIGHT(B1, 5)") == .text("World"))
    #expect(value("RIGHT(B1, 50)") == .text("Hello World"))
    #expect(value("LEFT(B1, -1)") == .error("#VALUE!"))
    #expect(value("MID(B1, 7, 3)") == .text("Wor"))
    #expect(value("MID(B1, 0, 3)") == .error("#VALUE!"))
    #expect(value("TRIM(\"  a   b  \")") == .text("a b"))
    #expect(value("SUBSTITUTE(\"a-b-c\", \"-\", \"+\")") == .text("a+b+c"))
    #expect(value("SUBSTITUTE(\"a-b-c\", \"-\", \"+\", 2)") == .text("a-b+c"))
    #expect(value("SUBSTITUTE(\"a-b-c\", \"-\", \"+\", 3)") == .text("a-b-c"))
    #expect(value("REPLACE(\"abcdef\", 2, 3, \"X\")") == .text("aXef"))
    #expect(value("FIND(\"o\", B1)") == .number(5))
    #expect(value("FIND(\"o\", B1, 6)") == .number(8))
    #expect(value("FIND(\"w\", B1)") == .error("#VALUE!"))
    #expect(value("SEARCH(\"w\", B1)") == .number(7))
    #expect(value("SEARCH(\"w?r\", B1)") == .number(7))
    #expect(value("SEARCH(\"z\", B1)") == .error("#VALUE!"))
    // A start one past the end of the text is out of range, not a scan with an inverted
    // window: the scan loop built (start - 1)...(count - needle) below the last position and
    // trapped the process where Excel answers #VALUE!.
    #expect(value("FIND(\"o\", B1, 12)") == .error("#VALUE!"))
    #expect(value("SEARCH(\"o\", B1, 12)") == .error("#VALUE!"))
    #expect(value("FIND(\"World\", B1, 8)") == .error("#VALUE!"))
    #expect(value("SEARCH(\"l*d\", B1, 12)") == .error("#VALUE!"))
    // Searching the last character is still in range, and an empty needle keeps its position.
    #expect(value("FIND(\"d\", B1, 11)") == .number(11))
    #expect(value("FIND(\"\", B1, 12)") == .number(12))
    #expect(value("PROPER(\"hello wORLD 2nd-place\")") == .text("Hello World 2Nd-Place"))
    #expect(value("REPT(\"ab\", 3)") == .text("ababab"))
    #expect(value("REPT(\"ab\", -1)") == .error("#VALUE!"))
    #expect(value("TEXTJOIN(\", \", TRUE, A1:A3, \"d\")") == .text("a, c, d"))
    #expect(value("TEXTJOIN(\"-\", FALSE, A1:A3)") == .text("a--c"))
    #expect(value("VALUE(\"1,234.5\")") == .number(1234.5))
    #expect(value("VALUE(\"12%\")") == .number(0.12))
    #expect(value("VALUE(\"2026-10-11\")") == .number(46306))
    #expect(value("VALUE(\"abc\")") == .error("#VALUE!"))
    #expect(value("LEFT(1/0, 1)") == .error("#DIV/0!"))
  }

  @Test("TEXT applies number and date formats")
  func textFormats() {
    let evaluator = SpreadsheetEvaluator(
      Spreadsheet(cells: ["A1": "1234.567", "A2": "2026-03-05"]))
    func value(_ formula: String) -> CellValue { evaluator.evaluate(formula: formula) }
    #expect(value("TEXT(A1, \"0\")") == .text("1235"))
    #expect(value("TEXT(A1, \"0.00\")") == .text("1234.57"))
    #expect(value("TEXT(A1, \"#,##0\")") == .text("1,235"))
    #expect(value("TEXT(A1, \"#,##0.00\")") == .text("1,234.57"))
    #expect(value("TEXT(1234567.891, \"#,##0.00\")") == .text("1,234,567.89"))
    #expect(value("TEXT(0.256, \"0%\")") == .text("26%"))
    #expect(value("TEXT(0.256, \"0.0%\")") == .text("25.6%"))
    #expect(value("TEXT(A1, \"$#,##0\")") == .text("$1,235"))
    #expect(value("TEXT(-1234.5, \"$#,##0\")") == .text("-$1,235"))
    #expect(value("TEXT(2.345, \"0.00\")") == .text("2.35"))
    #expect(value("TEXT(0.5, \"#.##\")") == .text(".5"))
    #expect(value("TEXT(7, \"000\")") == .text("007"))
    #expect(value("TEXT(A2, \"yyyy-mm-dd\")") == .text("2026-03-05"))
    #expect(value("TEXT(A2, \"dd/mm/yy\")") == .text("05/03/26"))
    #expect(value("TEXT(A2, \"mmm d, yyyy\")") == .text("Mar 5, 2026"))
    #expect(value("TEXT(A2, \"dddd\")") == .text("Thursday"))
    #expect(value("TEXT(46000, \"yyyy-mm-dd\")") == .text("2025-12-09"))
    #expect(value("TEXT(\"abc\", \"0.00\")") == .text("abc"))
    #expect(value("TEXT(A1, \"General\")") == .text("1234.567"))
    #expect(value("\"Total: \"&TEXT(A1, \"$#,##0.00\")") == .text("Total: $1,234.57"))
  }

  @Test("Date functions use ISO text and Excel serials")
  func dateFunctions() {
    let evaluator = SpreadsheetEvaluator(
      Spreadsheet(cells: ["A1": "2024-02-29", "A2": "2024/03/10"]))
    func value(_ formula: String) -> CellValue { evaluator.evaluate(formula: formula) }
    #expect(value("DATE(2026, 10, 11)") == .text("2026-10-11"))
    #expect(value("DATE(2026, 13, 1)") == .text("2027-01-01"))
    #expect(value("DATE(2026, 0, 1)") == .text("2025-12-01"))
    #expect(value("DATE(2026, 3, 0)") == .text("2026-02-28"))
    #expect(value("DATE(2024, 2, 30)") == .text("2024-03-01"))
    #expect(value("DATE(126, 1, 1)") == .text("2026-01-01"))
    #expect(value("DATE(-1, 1, 1)") == .error("#NUM!"))
    #expect(value("YEAR(A1)") == .number(2024))
    #expect(value("MONTH(A1)") == .number(2))
    #expect(value("DAY(A1)") == .number(29))
    #expect(value("DAY(A2)") == .number(10))
    #expect(value("YEAR(\"2026-10-11 14:30\")") == .number(2026))
    #expect(value("MONTH(46306)") == .number(10))
    #expect(value("YEAR(\"soon\")") == .error("#VALUE!"))
    #expect(value("DAY(\"2023-02-29\")") == .error("#VALUE!"))
    #expect(value("DAYS(A2, A1)") == .number(10))
    #expect(value("DAYS(\"2026-01-01\", \"2025-01-01\")") == .number(365))
    #expect(value("DAYS(DATE(2026, 1, 1), A1)") == .number(672))
    #expect(value("YEAR(TODAY()) = YEAR(NOW())") == .bool(true))
    if case .text(let now) = value("NOW()") {
      #expect(now.count == 16)
    } else {
      Issue.record("NOW() should return ISO date-time text")
    }
  }

  @Test("XOR and IS functions inspect values")
  func informationFunctions() {
    let evaluator = SpreadsheetEvaluator(
      Spreadsheet(cells: ["A1": "5", "A2": "text", "A3": "=1/0", "A4": "TRUE"]))
    func value(_ formula: String) -> CellValue { evaluator.evaluate(formula: formula) }
    #expect(value("XOR(TRUE, FALSE)") == .bool(true))
    #expect(value("XOR(TRUE, TRUE)") == .bool(false))
    #expect(value("XOR(TRUE, TRUE, TRUE)") == .bool(true))
    #expect(value("XOR(A2)") == .error("#VALUE!"))
    #expect(value("ISBLANK(B1)") == .bool(true))
    #expect(value("ISBLANK(A1)") == .bool(false))
    #expect(value("ISNUMBER(A1)") == .bool(true))
    #expect(value("ISNUMBER(A2)") == .bool(false))
    #expect(value("ISTEXT(A2)") == .bool(true))
    #expect(value("ISTEXT(A4)") == .bool(false))
    #expect(value("ISERROR(A3)") == .bool(true))
    #expect(value("ISERROR(A1)") == .bool(false))
    #expect(value("IF(ISERROR(A3), \"bad\", A3)") == .text("bad"))
    #expect(value("#REF!+1") == .error("#REF!"))
    #expect(value("ISERROR(#N/A)") == .bool(true))
    #expect(value("SUMIF(A1:A3, \">0\")") == .number(5))
    #expect(value("SUM(A1:A3)") == .error("#DIV/0!"))
  }

  // MARK: Catalog

  @Test("Function catalog is sorted, complete and implemented")
  func catalog() {
    let names = SpreadsheetFunctions.all.map(\.name)
    #expect(names == names.sorted())
    #expect(Set(names).count == names.count)
    #expect(names.count == 81)
    for required in [
      "SUM", "AVERAGE", "MIN", "MAX", "COUNT", "COUNTA", "ROUND", "ABS", "IF", "AND", "OR", "NOT",
      "CONCAT", "CONCATENATE", "LEN", "UPPER", "LOWER", "TODAY", "SUMIF", "VLOOKUP", "XLOOKUP",
      "TEXT", "TEXTJOIN", "DAYS", "XOR",
    ] {
      #expect(names.contains(required), "missing \(required)")
    }
    let evaluator = SpreadsheetEvaluator(Spreadsheet())
    for function in SpreadsheetFunctions.all {
      #expect(function.signature.hasPrefix(function.name + "("))
      #expect(function.summary.hasSuffix("."))
      #expect(
        evaluator.evaluate(formula: "\(function.name)()") != .error("#NAME?"),
        "\(function.name) is not implemented")
    }
  }

  @Test("Catalog matching ranks common functions for short prefixes")
  func catalogMatching() {
    #expect(
      SpreadsheetFunctions.matching(prefix: "").prefix(7).map(\.name) == [
        "SUM", "AVERAGE", "IF", "VLOOKUP", "COUNT", "MAX", "MIN",
      ])
    #expect(SpreadsheetFunctions.matching(prefix: "").count == SpreadsheetFunctions.all.count)
    #expect(SpreadsheetFunctions.matching(prefix: "s").first?.name == "SUM")
    #expect(
      SpreadsheetFunctions.matching(prefix: "co").map(\.name) == [
        "COUNT", "CONCAT", "CONCATENATE", "COUNTA", "COUNTBLANK", "COUNTIF", "COUNTIFS",
      ])
    #expect(SpreadsheetFunctions.matching(prefix: "sumi").map(\.name) == ["SUMIF", "SUMIFS"])
    #expect(SpreadsheetFunctions.matching(prefix: "=vl").map(\.name) == ["VLOOKUP"])
    #expect(SpreadsheetFunctions.matching(prefix: "zzz").isEmpty)
  }

  // MARK: Formula text helpers

  @Test("References are found with their text ranges")
  func formulaReferences() {
    let formula = "=SUM(A1:b3, $C$4) + LOG10(D5) & \"E6\" + ZZ1 + 1.5E3"
    let references = SpreadsheetFormula.references(in: formula)
    #expect(references.map { String(formula[$0.range]) } == ["A1:b3", "$C$4", "D5", "ZZ1"])
    #expect(references[0].start == CellAddress("A1"))
    #expect(references[0].end == CellAddress("B3"))
    #expect(references[1].start == references[1].end)
    #expect(references[1].start == CellAddress("C4"))
    #expect(SpreadsheetFormula.references(in: "=A1 : B2")[0].end == CellAddress("B2"))
    #expect(
      SpreadsheetFormula.references(in: "=\"a\"\"A1\"\"\"&B1").map(\.start) == [CellAddress("B1")])
    #expect(SpreadsheetFormula.references(in: "plain").isEmpty)
  }

  @Test("Shifting moves relative references like Excel copy")
  func formulaShifting() {
    #expect(SpreadsheetFormula.shifted("=A1+B2", rows: 1, columns: 2) == "=C2+D3")
    #expect(SpreadsheetFormula.shifted("=$A1+A$1+$A$1", rows: 2, columns: 1) == "=$A3+B$1+$A$1")
    #expect(SpreadsheetFormula.shifted("=SUM(A1:B2)*2", rows: 3, columns: 0) == "=SUM(A4:B5)*2")
    #expect(SpreadsheetFormula.shifted("=sum(a1:$b$2)", rows: 1, columns: 1) == "=sum(B2:$B$2)")
    #expect(SpreadsheetFormula.shifted("=A1&\"A1\"", rows: 1, columns: 0) == "=A2&\"A1\"")
    #expect(SpreadsheetFormula.shifted("=A1+1", rows: -1, columns: 0) == "=#REF!+1")
    #expect(SpreadsheetFormula.shifted("=SUM(A2:B3)", rows: 0, columns: -1) == "=SUM(#REF!)")
    #expect(SpreadsheetFormula.shifted("=$A$1", rows: -5, columns: -5) == "=$A$1")
    #expect(SpreadsheetFormula.shifted("=LOG10(A1)", rows: 1, columns: 0) == "=LOG10(A2)")
    #expect(SpreadsheetFormula.shifted("A1+1", rows: 1, columns: 1) == "A1+1")
    let evaluator = SpreadsheetEvaluator(Spreadsheet(cells: ["A1": "1"]))
    let shifted = SpreadsheetFormula.shifted("=A1*2", rows: -1, columns: 0)
    #expect(evaluator.evaluate(formula: shifted) == .error("#REF!"))
  }

  @Test("Reference insertion points follow operators and separators")
  func referenceInsertion() {
    func accepts(_ formula: String, at offset: Int? = nil) -> Bool {
      let caret = offset.map { formula.index(formula.startIndex, offsetBy: $0) } ?? formula.endIndex
      return SpreadsheetFormula.acceptsReference(formula, caret: caret)
    }
    #expect(accepts("="))
    #expect(accepts("=SUM("))
    #expect(accepts("=SUM(A1, "))
    #expect(accepts("=A1+"))
    #expect(accepts("=A1 * "))
    #expect(accepts("=A1:"))
    #expect(accepts("=A1<"))
    #expect(accepts("=\"x\"&"))
    #expect(!accepts("=A1"))
    #expect(!accepts("=SUM(A1)"))
    #expect(!accepts("SUM("))
    #expect(!accepts(""))
    #expect(!accepts("=\"a,"))
    #expect(accepts("=SUM(A1)", at: 5))
    #expect(!accepts("=SUM(A1)", at: 0))
  }

  @Test("Enclosing function tracks nested argument lists")
  func enclosingFunction() {
    func name(_ formula: String, at offset: Int? = nil) -> String? {
      let caret = offset.map { formula.index(formula.startIndex, offsetBy: $0) } ?? formula.endIndex
      return SpreadsheetFormula.enclosingFunction(formula, caret: caret)
    }
    #expect(name("=sum(") == "SUM")
    #expect(name("=SUM(A1, ") == "SUM")
    #expect(name("=IF(A1>0, VLOOKUP(A1, B1:C9, ") == "VLOOKUP")
    #expect(name("=IF(A1>0, VLOOKUP(A1, B1:C9, 2), ") == "IF")
    #expect(name("=SUM((A1+") == "SUM")
    #expect(name("=SUM(A1)") == nil)
    #expect(name("=(A1+") == nil)
    #expect(name("=A1") == nil)
    #expect(name("=CONCAT(\"(\", ") == "CONCAT")
    #expect(name("=LOG10(") == "LOG10")
    #expect(name("=ROUND(SUM(A1:A3), 2)", at: 11) == "SUM")
  }

  private func temporaryFile(_ data: Data, extension ext: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spreadsheet-test-\(UUID().uuidString).\(ext)")
    try data.write(to: url)
    return url
  }

  private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String)
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
  }
}
