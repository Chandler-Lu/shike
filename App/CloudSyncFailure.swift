import CloudKit
import Foundation
import ShikeCore

/// Diagnostics contain operation names, error codes and server trace metadata; never CKRecord payloads,
/// user-record IDs, account tokens, or the complete NSError.userInfo dictionary.
struct CloudSyncFailure: Equatable {
    let message: String
    let diagnostic: String
    let automaticRetryAllowed: Bool
    let retryAfter: TimeInterval?

    init(_ error: Error, operation: String, container: String) {
        var codes: [String] = [], seen = Set<String>(), retry: TimeInterval?
        var httpStatuses = Set<Int>(), requestIDs = Set<String>(), operationIDs = Set<String>()
        var cloudCodes = Set<Int>()
        func inspect(_ error: NSError, depth: Int) {
            guard depth < 5 else { return }
            let key = "\(error.domain)(\(error.code))"
            if seen.insert(key).inserted { codes.append(key) }
            if error.domain == CKErrorDomain { cloudCodes.insert(error.code) }
            if let status = error.userInfo["CKHTTPStatus"] as? NSNumber, (100...599).contains(status.intValue) { httpStatuses.insert(status.intValue) }
            if let request = error.userInfo["RequestUUID"] as? String, let id = UUID(uuidString: request) { requestIDs.insert(id.uuidString) }
            if let operation = error.userInfo["OperationID"] as? String,
               (8...64).contains(operation.count), operation.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) { operationIDs.insert(operation) }
            if let value = error.userInfo[CKErrorRetryAfterKey] as? NSNumber { retry = max(retry ?? 0, value.doubleValue) }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { inspect(underlying, depth: depth + 1) }
            if let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                for child in partial.values { inspect(child as NSError, depth: depth + 1) }
            }
        }
        inspect(error as NSError, depth: 0)
        let nserror = error as NSError
        let hint: String
        if cloudCodes.contains(CKError.serverRejectedRequest.rawValue) {
            hint = "CloudKit 服务器拒绝请求（15）。此错误码不能单独确定原因，请查看同步诊断中的失败步骤与请求编号后重试。"
        } else if !cloudCodes.isDisjoint(with: [CKError.badContainer.rawValue, CKError.missingEntitlement.rawValue, CKError.permissionFailure.rawValue, CKError.invalidArguments.rawValue]) {
            hint = "iCloud 容器或签名配置未就绪，请检查容器关联、描述文件和云端结构。"
        } else if cloudCodes.contains(CKError.notAuthenticated.rawValue) {
            hint = "请在系统设置中登录 iCloud，然后重新检查同步。"
        } else if cloudCodes.contains(CKError.quotaExceeded.rawValue) {
            hint = "iCloud 空间不足，请释放空间后重试。"
        } else if !cloudCodes.isDisjoint(with: [CKError.networkFailure.rawValue, CKError.networkUnavailable.rawValue, CKError.serviceUnavailable.rawValue, CKError.requestRateLimited.rawValue, CKError.zoneBusy.rawValue, CKError.accountTemporarilyUnavailable.rawValue]) {
            hint = "iCloud 暂时不可用，稍后会重试。"
        } else if nserror.domain == CKErrorDomain { hint = "iCloud 同步未完成（\(nserror.code)），请查看诊断后重试。" }
        else if let value = error as? ShikeError { hint = value.localizedDescription }
        else { hint = "同步数据暂时无法读取或保存，请稍后重试。" }
        message = "\(operation)：\(hint) 本地倒数日已保留。"
        var details = ["时间：\(ISO8601DateFormatter().string(from: .now))", "操作：\(operation)", "容器：\(container)", "错误链：\(codes.joined(separator: " → "))"]
        if !httpStatuses.isEmpty { details.append("HTTP：\(httpStatuses.sorted().map(String.init).joined(separator: ", "))") }
        if !requestIDs.isEmpty { details.append("请求编号：\(requestIDs.sorted().joined(separator: ", "))") }
        if !operationIDs.isEmpty { details.append("操作编号：\(operationIDs.sorted().joined(separator: ", "))") }
        diagnostic = details.joined(separator: "\n")
        let permanent = [CKError.serverRejectedRequest.rawValue, CKError.badContainer.rawValue, CKError.missingEntitlement.rawValue, CKError.permissionFailure.rawValue, CKError.invalidArguments.rawValue]
        automaticRetryAllowed = cloudCodes.isDisjoint(with: permanent)
        retryAfter = retry
    }
}

#if DEBUG
/// Explicit launch-only diagnostics. Fetches zone metadata without user record contents.
/// Normal countdown synchronization is suspended while this probe runs.
enum CloudKitReadOnlyProbe {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-cloudkit-diagnose-readonly") }
    private static func log(_ text: String) { print("[CloudKitProbe] \(ISO8601DateFormatter().string(from: .now)) \(text)") }
    static func run() async {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "ShikeCloudContainer") as? String ?? "iCloud.com.chandler.shike"
        let container = CKContainer(identifier: identifier)
        log("BEGIN container=\(identifier) mode=READ_ONLY")
        do { log("accountStatus=\(try await container.accountStatus().rawValue)") }
        catch { describe(error); return }
        let account: CKRecord.ID
        do { account = try await container.userRecordID(); log("userRecordID=available (redacted)") }
        catch { describe(error); return }
        await fetch("private.default", database: container.privateCloudDatabase, ids: [CKRecordZone.default().zoneID], redacting: account.recordName)
        await fetch("private.countdowns.defaultOwner", database: container.privateCloudDatabase, ids: [CKRecordZone.ID(zoneName: "ShikeCountdowns")], redacting: account.recordName)
        await fetch("private.countdowns.explicitOwner", database: container.privateCloudDatabase, ids: [CKRecordZone.ID(zoneName: "ShikeCountdowns", ownerName: account.recordName)], redacting: account.recordName)
        await fetch("private.allZones", database: container.privateCloudDatabase, ids: nil, redacting: account.recordName)
        await fetch("public.default", database: container.publicCloudDatabase, ids: [CKRecordZone.default().zoneID], redacting: account.recordName)
        if ProcessInfo.processInfo.arguments.contains("-cloudkit-diagnose-schema") {
            await schema(database: container.publicCloudDatabase, redacting: account.recordName)
        }
        log("END")
    }
    private static func schema(database: CKDatabase, redacting account: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let operation = CKQueryOperation(query: CKQuery(recordType: "ShikeCountdownRecord", predicate: NSPredicate(value: true)))
            operation.desiredKeys = []; operation.resultsLimit = 1
            operation.configuration.timeoutIntervalForRequest = 20
            operation.configuration.timeoutIntervalForResource = 30
            log("START public.schema ShikeCountdownRecord metadataOnly operationID=\(operation.operationID)")
            operation.recordMatchedBlock = { _, _ in } // Do not log IDs or field data.
            operation.queryResultBlock = { result in
                switch result {
                case .success: log("DONE public.schema=OK")
                case .failure(let error): log("DONE public.schema=FAILED"); describe(error, redacting: account)
                }
                continuation.resume()
            }
            database.add(operation)
        }
    }
    private static func fetch(_ label: String, database: CKDatabase, ids: [CKRecordZone.ID]?, redacting account: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let operation = ids.map { CKFetchRecordZonesOperation(recordZoneIDs: $0) } ?? CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
            operation.configuration.timeoutIntervalForRequest = 20
            operation.configuration.timeoutIntervalForResource = 30
            log("START \(label) operationID=\(operation.operationID)")
            operation.perRecordZoneResultBlock = { _, result in
                switch result {
                case .success: log("\(label) zone=OK")
                case .failure(let error): log("\(label) zone=FAILED"); describe(error, redacting: account)
                }
            }
            operation.fetchRecordZonesResultBlock = { result in
                switch result {
                case .success: log("DONE \(label)=OK")
                case .failure(let error): log("DONE \(label)=FAILED"); describe(error, redacting: account)
                }
                continuation.resume()
            }
            database.add(operation)
        }
    }
    static func describe(_ error: Error, redacting account: String = "", depth: Int = 0) {
        guard depth < 5 else { return }
        let value = error as NSError
        log("error=\(value.domain)(\(value.code)) keys=\(value.userInfo.keys.sorted())")
        // Whitelist server messages/status only; never print arbitrary error dictionaries.
        for key in [NSLocalizedDescriptionKey, NSDebugDescriptionErrorKey, NSLocalizedFailureReasonErrorKey, "CKErrorDescription", "ServerDescription", "ServerErrorDescription", "CKHTTPStatus", "HTTPStatusCode", "CKHTTPStatusCode", "RequestUUID", CKErrorRetryAfterKey] {
            guard let detail = value.userInfo[key], detail is String || detail is NSNumber else { continue }
            var text = String(describing: detail)
            if !account.isEmpty { text = text.replacingOccurrences(of: account, with: "<account>") }
            log("\(key)=\(text.prefix(1500))")
        }
        if let headers = value.userInfo["CKDHTTPHeaders"] as? [String: Any] {
            log("HTTP header names=\(headers.keys.sorted())")
            for (key, detail) in headers where ["date", "server", "content-type", "x-apple-request-uuid", "x-apple-cloudkit-error-code"].contains(key.lowercased()) {
                log("header \(key)=\(detail)")
            }
        }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError { describe(underlying, redacting: account, depth: depth + 1) }
        if let partial = value.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            for child in partial.values { describe(child, redacting: account, depth: depth + 1) }
        }
    }
}
#endif
