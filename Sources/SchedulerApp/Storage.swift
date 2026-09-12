import Foundation
import Security
import SQLite3
import SchedulerCore

struct SavedDraft: Codable {
    var text: String
    var drafts: [Draft]
    var questions: [String]
    var updatedAt = Date()
}

final class LocalStore {
    let directory: URL
    private var database: OpaquePointer?
    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudScheduler", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dbURL = self.directory.appendingPathComponent("operations.sqlite")
        guard sqlite3_open_v2(dbURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw AppError("无法打开操作记录，已停止日历写入。") }
        try run("PRAGMA journal_mode=WAL;")
        try run("PRAGMA synchronous=FULL;")
        try run("CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, created REAL NOT NULL, status TEXT NOT NULL, payload BLOB NOT NULL);")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbURL.path)
    }
    deinit { sqlite3_close(database) }
    private func run(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw AppError("无法保存操作记录；请检查磁盘空间与文件权限。") }
    }
    func loadPreferences() throws -> AppPreferences {
        let url = directory.appendingPathComponent("preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AppPreferences() }
        do { return try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: url)) }
        catch { throw AppError("配置文件无法读取，原文件已保留：\(url.path)") }
    }
    func savePreferences(_ preferences: AppPreferences) throws { try write(preferences, name: "preferences.json") }
    func saveDraft(_ draft: SavedDraft) throws { try write(draft, name: "draft.json") }
    func loadDraft() throws -> SavedDraft? {
        let url = directory.appendingPathComponent("draft.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let draft = try JSONDecoder().decode(SavedDraft.self, from: Data(contentsOf: url))
        return draft.updatedAt > Date().addingTimeInterval(-7 * 86400) ? draft : nil
    }
    func clearDraft() throws {
        let url = directory.appendingPathComponent("draft.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        let data = try JSONEncoder().encode(value)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func record(_ receipt: OperationReceipt) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO operations (id,created,status,payload) VALUES (?,?,?,?);", -1, &statement, nil) == SQLITE_OK else { throw AppError("无法准备操作记录。") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, receipt.id.uuidString, -1, transient)
        sqlite3_bind_double(statement, 2, receipt.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, receipt.status, -1, transient)
        let data = try JSONEncoder().encode(receipt)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError("操作记录写入失败。请先核对系统日历，不要重复提交。") }
    }
    func receipts() throws -> [OperationReceipt] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT payload FROM operations ORDER BY created DESC;", -1, &statement, nil) == SQLITE_OK else { throw AppError("无法读取操作记录。") }
        defer { sqlite3_finalize(statement) }
        var result: [OperationReceipt] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw AppError("操作记录损坏，原记录已保留。") }
            result.append(try JSONDecoder().decode(OperationReceipt.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
        return result
    }
    func prune() throws {
        // Keep unresolved writes indefinitely: age alone is not proof they never reached EventKit.
        let cutoff = Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970
        try run("DELETE FROM operations WHERE created < \(cutoff) AND status IN ('saved','undone','failed');")
    }
}

enum KeychainStore {
    private static let service = "dev.icloudscheduler.app.api-keys"
    // Query metadata only: opening the selector must not read keys or prompt for access.
    static func contains(provider: String) -> Bool {
        var query = base(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    static func read(provider: String) throws -> String {
        var query = base(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return "" }
        guard code == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw AppError("无法读取钥匙串（\(code)）。请在设置中重新保存密钥。") }
        return key
    }
    static func save(_ key: String, provider: String) throws {
        let query = base(provider)
        if key.isEmpty {
            let code = SecItemDelete(query as CFDictionary)
            guard code == errSecSuccess || code == errSecItemNotFound else { throw AppError("无法删除钥匙串密钥（\(code)）。") }
            return
        }
        let data = Data(key.utf8)
        var code = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if code == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            code = SecItemAdd(item as CFDictionary, nil)
        }
        guard code == errSecSuccess else { throw AppError("无法保存钥匙串密钥（\(code)）。") }
    }
    private static func base(_ provider: String) -> [String: Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:provider]
    }
}
