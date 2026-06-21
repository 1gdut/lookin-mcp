//
//  main.swift
//  lookinextension
//
//  Created by xrt on 2026/6/20.
//

import Foundation

enum CLIError: Error, LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        }
    }
}

enum LookinExtensionCLI {
    private static let usageText = """
    Usage:
      lookinextension list-targets
      lookinextension list-sessions
      lookinextension connect --target <target-id>
      lookinextension disconnect --session <session-id>
      lookinextension list-snapshots [--session <session-id>]
      lookinextension capture-snapshot --session <session-id> [--name <name>] [--depth <n>] [--include-hidden true|false] [--focus-path 0,1,2]
      lookinextension diff-hierarchy --session <session-id> --snapshot-a <snapshot-id> --snapshot-b <snapshot-id>
      lookinextension ping (--target <target-id> | --session <session-id>)
      lookinextension hierarchy (--target <target-id> | --session <session-id>) [--depth <n>] [--include-hidden true|false] [--focus-path 0,1,2]
      lookinextension find-nodes (--target <target-id> | --session <session-id>) [--node-id <oid>] [--class-name-contains <text>] [--custom-title-contains <text>] [--memory-address-contains <text>] [--text-contains <text>] [--identifier-contains <text>] [--hidden true|false] [--frame x,y,width,height] [--frame-match exact|intersects|contains] [--limit <n>]
      lookinextension object (--target <target-id> | --session <session-id>) --node-id <oid>
      lookinextension view-details (--target <target-id> | --session <session-id>) --node-id <oid> [--screenshot-mode none|group|solo] [--include-subitems]
      lookinextension screenshot (--target <target-id> | --session <session-id>) [--node-id <oid>] [--mode app|group|solo]
      lookinextension daemon
    """

    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            throw CLIError.usage(usageText)
        }

        let service = LKXBridgeService()

        switch command {
        case "--help", "-h", "help":
            throw CLIError.usage(usageText)
        case "daemon":
            service.persistentConnectionsEnabled = true
            runDaemon(with: service)
            return
        default:
            let result = try execute(command: command, args: Array(args.dropFirst()), service: service)
            emitSuccess(result)
            return
        }
    }

    private static func runDaemon(with service: LKXBridgeService) {
        while let line = readLine() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            var requestID: Any = NSNull()
            do {
                let requestObject = try parseJSONObject(from: line)
                requestID = requestObject["id"] ?? NSNull()
                guard let command = requestObject["command"] as? String else {
                    throw CLIError.usage("Missing daemon field: command")
                }

                let commandArgs = requestObject["args"] as? [String] ?? []
                let result = try execute(command: command, args: commandArgs, service: service)
                emitStreamJSON([
                    "id": requestID,
                    "ok": true,
                    "result": result
                ])
            } catch {
                let nsError = error as NSError
                emitStreamJSON([
                    "id": requestID,
                    "ok": false,
                    "error": [
                        "code": nsError.userInfo["bridge_code"] as? String ?? "cli_error",
                        "message": nsError.localizedDescription
                    ]
                ])
            }
        }
    }

    private static func execute(command: String, args: [String], service: LKXBridgeService) throws -> Any {
        let semaphore = DispatchSemaphore(value: 0)
        var resultPayload: Any?
        var resultError: Error?

        func finish(_ payload: Any?, _ error: Error?) {
            resultPayload = payload
            resultError = error
            semaphore.signal()
        }

        switch command {
        case "list-targets":
            service.listTargets { targets, error in
                finish(targets ?? [], error)
            }

        case "list-sessions":
            service.listSessions { sessions, error in
                finish(sessions ?? [], error)
            }

        case "connect":
            let targetID = try requiredTargetID(from: args)
            service.createSession(forTarget: targetID) { result, error in
                finish(result ?? [:], error)
            }

        case "disconnect":
            let sessionID = try requiredSessionID(from: args)
            service.deleteSession(sessionID) { result, error in
                finish(result ?? [:], error)
            }

        case "list-snapshots":
            let sessionID = optionalValue(flag: "--session", from: args)
            service.listSnapshots(forSession: sessionID) { snapshots, error in
                finish(snapshots ?? [], error)
            }

        case "capture-snapshot":
            let sessionID = try requiredSessionID(from: args)
            let name = optionalValue(flag: "--name", from: args)
            let options = try hierarchyOptions(from: args)
            service.captureSnapshot(forSession: sessionID, name: name, options: options) { result, error in
                finish(result ?? [:], error)
            }

        case "diff-hierarchy":
            let sessionID = try requiredSessionID(from: args)
            guard let snapshotAID = optionalValue(flag: "--snapshot-a", from: args), !snapshotAID.isEmpty,
                  let snapshotBID = optionalValue(flag: "--snapshot-b", from: args), !snapshotBID.isEmpty else {
                throw CLIError.usage("Missing required arguments: --snapshot-a <snapshot-id> --snapshot-b <snapshot-id>")
            }
            service.diffSnapshots(forSession: sessionID, snapshotA: snapshotAID, snapshotB: snapshotBID) { result, error in
                finish(result ?? [:], error)
            }

        case "ping":
            let (targetID, sessionID) = try requiredTargetOrSession(from: args)
            service.pingTarget(targetID, sessionID: sessionID) { result, error in
                finish(result ?? [:], error)
            }

        case "hierarchy":
            let (targetID, sessionID) = try requiredTargetOrSession(from: args)
            let options = try hierarchyOptions(from: args)
            service.fetchHierarchy(forTarget: targetID, sessionID: sessionID, options: options) { result, error in
                finish(result ?? [:], error)
            }

        case "find-nodes":
            let (targetID, sessionID) = try requiredTargetOrSession(from: args)
            var query: [String: Any] = [:]
            if let nodeID = try optionalUnsignedIntValue(flag: "--node-id", from: args) {
                query["node_id"] = nodeID
            }
            if let classNameContains = optionalValue(flag: "--class-name-contains", from: args) {
                query["class_name_contains"] = classNameContains
            }
            if let customTitleContains = optionalValue(flag: "--custom-title-contains", from: args) {
                query["custom_title_contains"] = customTitleContains
            }
            if let memoryAddressContains = optionalValue(flag: "--memory-address-contains", from: args) {
                query["memory_address_contains"] = memoryAddressContains
            }
            if let textContains = optionalValue(flag: "--text-contains", from: args) {
                query["text_contains"] = textContains
            }
            if let identifierContains = optionalValue(flag: "--identifier-contains", from: args) {
                query["identifier_contains"] = identifierContains
            }
            if let hidden = try optionalBoolValue(flag: "--hidden", from: args) {
                query["hidden"] = hidden
            }
            if let frame = try optionalRectDictionaryValue(flag: "--frame", from: args) {
                query["frame"] = frame
            }
            if let frameMatch = optionalValue(flag: "--frame-match", from: args) {
                query["frame_match"] = frameMatch
            }
            if let limit = try optionalUnsignedIntValue(flag: "--limit", from: args) {
                query["limit"] = limit
            }
            service.findNodes(forTarget: targetID, sessionID: sessionID, query: query) { result, error in
                finish(result ?? [:], error)
            }

        case "object":
            let (targetID, sessionID) = try requiredTargetOrSession(from: args)
            let nodeID = try requiredUnsignedIntValue(flag: "--node-id", from: args)
            service.fetchObject(forTarget: targetID, sessionID: sessionID, nodeID: nodeID) { result, error in
                finish(result ?? [:], error)
            }

        case "view-details":
            let (targetID, sessionID) = try requiredTargetOrSession(from: args)
            let nodeID = try requiredUnsignedIntValue(flag: "--node-id", from: args)
            let screenshotMode = optionalValue(flag: "--screenshot-mode", from: args) ?? "none"
            let includeSubitems = args.contains("--include-subitems")
            service.fetchViewDetails(forTarget: targetID, sessionID: sessionID, nodeID: nodeID, screenshotMode: screenshotMode, includeSubitems: includeSubitems) { result, error in
                finish(result ?? [:], error)
            }

        case "screenshot":
            let (targetID, sessionID) = try requiredTargetOrSession(from: args)
            let nodeID = try optionalUnsignedIntValue(flag: "--node-id", from: args)
            let mode = optionalValue(flag: "--mode", from: args) ?? (nodeID == nil ? "app" : "group")
            service.fetchScreenshot(forTarget: targetID, sessionID: sessionID, nodeID: nodeID.map(NSNumber.init(value:)), mode: mode) { result, error in
                finish(result ?? [:], error)
            }

        default:
            throw CLIError.usage("Unknown command: \(command)\n\n\(usageText)")
        }

        semaphore.wait()

        if let resultError {
            throw resultError
        }

        return resultPayload ?? [:]
    }

    private static func parseJSONObject(from line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.usage("Failed to parse daemon request JSON.")
        }
        return object
    }

    private static func requiredTargetID(from args: [String]) throws -> String {
        guard let flagIndex = args.firstIndex(of: "--target"), args.indices.contains(flagIndex + 1) else {
            throw CLIError.usage("Missing required argument: --target <target-id>")
        }
        return args[flagIndex + 1]
    }

    private static func requiredSessionID(from args: [String]) throws -> String {
        guard let sessionID = optionalValue(flag: "--session", from: args), !sessionID.isEmpty else {
            throw CLIError.usage("Missing required argument: --session <session-id>")
        }
        return sessionID
    }

    private static func requiredTargetOrSession(from args: [String]) throws -> (String?, String?) {
        let targetID = optionalValue(flag: "--target", from: args)
        let sessionID = optionalValue(flag: "--session", from: args)
        if let targetID, !targetID.isEmpty {
            return (targetID, nil)
        }
        if let sessionID, !sessionID.isEmpty {
            return (nil, sessionID)
        }
        throw CLIError.usage("Missing required arguments: provide either --target <target-id> or --session <session-id>")
    }

    private static func requiredUnsignedIntValue(flag: String, from args: [String]) throws -> UInt {
        guard let raw = optionalValue(flag: flag, from: args), let value = UInt(raw) else {
            throw CLIError.usage("Missing required argument: \(flag) <number>")
        }
        return value
    }

    private static func optionalUnsignedIntValue(flag: String, from args: [String]) throws -> UInt? {
        guard let raw = optionalValue(flag: flag, from: args) else {
            return nil
        }
        guard let value = UInt(raw) else {
            throw CLIError.usage("Invalid numeric value for \(flag): \(raw)")
        }
        return value
    }

    private static func optionalBoolValue(flag: String, from args: [String]) throws -> Bool? {
        guard let raw = optionalValue(flag: flag, from: args) else {
            return nil
        }
        switch raw.lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            throw CLIError.usage("Invalid boolean value for \(flag): \(raw)")
        }
    }

    private static func optionalRectDictionaryValue(flag: String, from args: [String]) throws -> [String: Double]? {
        guard let raw = optionalValue(flag: flag, from: args) else {
            return nil
        }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let width = Double(parts[2]),
              let height = Double(parts[3]) else {
            throw CLIError.usage("Invalid rect value for \(flag). Expected x,y,width,height")
        }
        return [
            "x": x,
            "y": y,
            "width": width,
            "height": height,
        ]
    }

    private static func optionalPathValue(flag: String, from args: [String]) throws -> [NSNumber]? {
        guard let raw = optionalValue(flag: flag, from: args), !raw.isEmpty else {
            return nil
        }
        let segments = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [NSNumber] = []
        for segment in segments {
            guard let value = Int(segment), value >= 0 else {
                throw CLIError.usage("Invalid focus path segment: \(segment)")
            }
            result.append(NSNumber(value: value))
        }
        return result
    }

    private static func hierarchyOptions(from args: [String]) throws -> [String: Any] {
        var options: [String: Any] = [:]
        if let depth = try optionalUnsignedIntValue(flag: "--depth", from: args) {
            options["depth"] = depth
        }
        if let includeHidden = try optionalBoolValue(flag: "--include-hidden", from: args) {
            options["include_hidden"] = includeHidden
        }
        if let focusPath = try optionalPathValue(flag: "--focus-path", from: args) {
            options["focus_path"] = focusPath
        }
        return options
    }

    private static func optionalValue(flag: String, from args: [String]) -> String? {
        guard let flagIndex = args.firstIndex(of: flag), args.indices.contains(flagIndex + 1) else {
            return nil
        }
        return args[flagIndex + 1]
    }

    private static func emitSuccess(_ result: Any) {
        let payload: [String: Any] = [
            "ok": true,
            "result": result
        ]
        emitJSON(payload)
    }

    static func emitFailure(_ error: Error) {
        let nsError = error as NSError
        let payload: [String: Any] = [
            "ok": false,
            "error": [
                "code": nsError.userInfo["bridge_code"] as? String ?? "cli_error",
                "message": nsError.localizedDescription
            ]
        ]
        emitJSON(payload)
    }

    private static func emitJSON(_ object: Any) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            fputs("{\"ok\":false,\"error\":{\"code\":\"json_encoding_failed\",\"message\":\"Failed to encode JSON.\"}}\n", stderr)
            return
        }
        print(text)
    }

    private static func emitStreamJSON(_ object: Any) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            fputs("{\"id\":null,\"ok\":false,\"error\":{\"code\":\"json_encoding_failed\",\"message\":\"Failed to encode JSON.\"}}\n", stderr)
            return
        }
        print(text)
        fflush(stdout)
    }
}

do {
    try LookinExtensionCLI.run()
} catch {
    LookinExtensionCLI.emitFailure(error)
    exit(1)
}
