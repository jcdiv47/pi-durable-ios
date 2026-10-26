import Foundation
import JavaScriptCore
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
/// Integers beyond this round-trip as BigInt instead of losing precision as a JS number.
private let maxSafeInteger: Int64 = 9_007_199_254_740_991

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

/// One sqlite3 connection, used only on the JS queue. Statements are cached by SQL text, as chord's
/// Node adapter does, and shared by the database and its transaction handles.
final class SQLiteConnection {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var columnNames: [OpaquePointer: [String]] = [:]

    init(path: String) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(db)
            db = nil
            throw SQLiteError(code: rc, message: message)
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA wal_autocheckpoint = 1000")
    }

    deinit { close() }

    func exec(_ sql: String) throws {
        guard let db else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed") }
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw SQLiteError(code: rc, message: message)
        }
    }

    func run(_ sql: String, _ params: JSValue) throws {
        let statement = try prepare(sql, params)
        defer { sqlite3_reset(statement) }
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return }
            if rc != SQLITE_ROW { throw currentError(rc) }
        }
    }

    func get(_ sql: String, _ params: JSValue, in context: JSContext) throws -> JSValue {
        let statement = try prepare(sql, params)
        defer { sqlite3_reset(statement) }
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { return JSValue(undefinedIn: context) }
        guard rc == SQLITE_ROW else { throw currentError(rc) }
        return row(statement, in: context)
    }

    func all(_ sql: String, _ params: JSValue, in context: JSContext) throws -> JSValue {
        let statement = try prepare(sql, params)
        defer { sqlite3_reset(statement) }
        let rows = JSValue(newArrayIn: context)!
        var index = 0
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return rows }
            guard rc == SQLITE_ROW else { throw currentError(rc) }
            rows.setValue(row(statement, in: context), at: index)
            index += 1
        }
    }

    func close() {
        guard let db else { return }
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        columnNames.removeAll()
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        sqlite3_close_v2(db)
        self.db = nil
    }

    // MARK: - Statements

    private func prepare(_ sql: String, _ params: JSValue) throws -> OpaquePointer {
        guard let db else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed") }
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        } else {
            var prepared: OpaquePointer?
            let rc = sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil)
            guard rc == SQLITE_OK, let prepared else { throw currentError(rc) }
            statements[sql] = prepared
            statement = prepared
        }
        try bind(statement, params)
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ params: JSValue) throws {
        let count = params.isUndefined || params.isNull ? 0 : Int(params.forProperty("length").toInt32())
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard count == expected else {
            throw SQLiteError(code: SQLITE_RANGE, message: "expected \(expected) bindings, got \(count)")
        }
        for index in 0..<count {
            let value = params.atIndex(index)!
            let position = Int32(index + 1)
            let rc: Int32
            if value.isNull || value.isUndefined {
                rc = sqlite3_bind_null(statement, position)
            } else if value.isString {
                // Explicit byte length: JS strings may contain NUL, which a C-string bind would cut at.
                var text = value.toString() ?? ""
                rc = text.withUTF8 { utf8 in
                    utf8.withMemoryRebound(to: CChar.self) {
                        sqlite3_bind_text(statement, position, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
                    }
                }
            } else if value.isNumber {
                let number = value.toDouble()
                if number.rounded() == number, abs(number) <= Double(maxSafeInteger) {
                    rc = sqlite3_bind_int64(statement, position, Int64(number))
                } else {
                    rc = sqlite3_bind_double(statement, position, number)
                }
            } else if JSBytes.isBigInt(value) {
                guard let integer = Int64(value.toString()) else {
                    throw SQLiteError(code: SQLITE_RANGE, message: "BigInt binding is outside the 64-bit range")
                }
                rc = sqlite3_bind_int64(statement, position, integer)
            } else if let data = JSBytes.data(of: value) {
                rc = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(bytes.count), SQLITE_TRANSIENT)
                }
            } else {
                throw SQLiteError(code: SQLITE_MISMATCH, message: "unsupported binding type at index \(index): \(value.toString() ?? "?")")
            }
            guard rc == SQLITE_OK else { throw currentError(rc) }
        }
    }

    private func row(_ statement: OpaquePointer, in context: JSContext) -> JSValue {
        let names = names(of: statement)
        let object = JSValue(newObjectIn: context)!
        for (column, name) in names.enumerated() {
            let i = Int32(column)
            let value: JSValue
            switch sqlite3_column_type(statement, i) {
            case SQLITE_INTEGER:
                let integer = sqlite3_column_int64(statement, i)
                value = abs(integer) <= maxSafeInteger
                    ? JSValue(double: Double(integer), in: context)
                    : JSBytes.bigInt(integer, in: context)
            case SQLITE_FLOAT:
                value = JSValue(double: sqlite3_column_double(statement, i), in: context)
            case SQLITE_TEXT:
                let text = sqlite3_column_text(statement, i)
                let length = Int(sqlite3_column_bytes(statement, i))
                let string = text.map {
                    String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
                } ?? ""
                value = JSValue(object: string, in: context)
            case SQLITE_BLOB:
                let length = Int(sqlite3_column_bytes(statement, i))
                if let blob = sqlite3_column_blob(statement, i), length > 0 {
                    value = JSBytes.uint8Array(UnsafeRawBufferPointer(start: blob, count: length), in: context)
                } else {
                    value = JSBytes.uint8Array(Data(), in: context)
                }
            default:
                value = JSValue(nullIn: context)
            }
            object.setValue(value, forProperty: name)
        }
        return object
    }

    private func names(of statement: OpaquePointer) -> [String] {
        // A schema change can reprepare a `SELECT *` with other columns, so the count guards the cache.
        if let cached = columnNames[statement], cached.count == Int(sqlite3_column_count(statement)) { return cached }
        let names = (0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
        columnNames[statement] = names
        return names
    }

    private func currentError(_ rc: Int32) -> SQLiteError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
        return SQLiteError(code: rc, message: message)
    }
}
