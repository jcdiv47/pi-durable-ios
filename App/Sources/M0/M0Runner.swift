import ActivityKit
import BackgroundTasks
import Foundation
import JavaScriptCore
import PiAppleTools
import PiRuntime
import PiUI
import UserNotifications
import WidgetKit

/// Headless M0 checks, selected with `-PiMode`. Each writes a JSON report to `Documents/m0/`.
@MainActor
enum M0Runner {
    // MARK: Kill test (scripts/kill-test.sh)

    static let killRequestId = "kill-1"

    /// Same place as the real session database: the App Group container's `pi/`.
    static func killDatabase() throws -> URL {
        try SharedContainer.directory("pi").appendingPathComponent("killtest.sqlite")
    }

    /// Phase 1: admit a turn whose tools take two minutes, then wait to be terminated.
    static func killTestStart(_ model: AppModel) async throws {
        let database = try killDatabase()
        M0Files.removeDatabase(database)
        let log = try LineLog(M0Files.url("killtest-start.jsonl"))
        log.append(#"{"type":"launched","runId":"\#(M0Files.runId)"}"#)
        let harness = try await PiHarness.load(bundle: AppModel.bundleURL, options: .init(
            onEvent: { log.append($0) },
            onLog: AppModel.forwardLog
        ))
        _ = try await harness.open(.init(dbPath: database.path, provider: "faux", modelId: "killtest", toolMs: 120_000))
        model.adopt(harness)
        try await harness.submit("go", requestId: killRequestId)
        log.append(#"{"type":"submitted"}"#)
        model.status = "Kill test: both tools are running for 120 s. Waiting to be terminated."
    }

    /// Phase 2, in a fresh process: `open` resumes the interrupted turn; the same requestId finds it.
    static func killTestResume(_ model: AppModel) async throws {
        let database = try killDatabase()
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw JSRuntimeError("No kill-test database; run -PiMode killtest-start first")
        }
        let log = try LineLog(M0Files.url("killtest-resume.jsonl"))
        let markers = MarkerCounter()
        let harness = try await PiHarness.load(bundle: AppModel.bundleURL, options: .init(
            onEvent: { json in
                log.append(json)
                markers.record(json)
            },
            onLog: AppModel.forwardLog
        ))
        let opened = try await harness.open(.init(dbPath: database.path, provider: "faux", modelId: "killtest", toolMs: 300))
        model.adopt(harness)
        model.status = "Kill test: resuming…"
        let json = try await harness.runtime.callAsync("PiRuntime.settle", ["go", killRequestId])
        let settled = try JSONDecoder().decode(PiHarness.SettleResult.self, from: Data(json.utf8))
        let lookup = settled.toolResults.first { $0.tool == "slow_lookup" }
        let send = settled.toolResults.first { $0.tool == "send_message" }
        let checks: [String: Bool] = [
            "turn finished": settled.status == "done",
            "slow_lookup reran exactly once": markers.count("slow_lookup", "start") == 1,
            "send_message did not rerun": markers.count("send_message", "start") == 0,
            "slow_lookup result is ok": lookup?.isError == false,
            "send_message result is interrupted": send?.isError == true && send?.text.contains("interrupted") == true,
            "model answered from both results": settled.answer == "Done: slow_lookup=ok, send_message=error",
        ]
        let pass = checks.values.allSatisfy(\.self)
        try M0Files.writeJSON("killtest-result.json", [
            "pass": pass,
            "checks": checks,
            "openMs": opened.openMs,
            "settle": (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? json,
        ])
        model.status = pass ? "Kill test passed" : "Kill test FAILED: \(checks.filter { !$0.value }.keys.sorted())"
    }

    // MARK: Capabilities

    static func capabilities(_ model: AppModel) async throws {
        var report: [String: Any] = [
            "environment": isSimulator ? "simulator" : "device",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "?",
        ]
        report["appGroup"] = appGroupCheck()
        report["keychain"] = keychainCheck()
        let health = await HealthAccess.probe()
        report["healthKit"] = ["available": health.available, "requestStatus": health.requestStatus]
        report["liveActivities"] = await liveActivityCheck()
        report["backgroundTasks"] = backgroundCheck()
        let notifications = await UNUserNotificationCenter.current().notificationSettings()
        report["notifications"] = ["authorizationStatus": notifications.authorizationStatus.rawValue]
        let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PiWidgets.appex").path
        report["widgetExtensionEmbedded"] = appex.map { FileManager.default.fileExists(atPath: $0) } ?? false
        if let configurations = try? await WidgetCenter.shared.currentConfigurations() {
            report["widgetsOnScreen"] = configurations.map { "\($0.kind) \($0.family)" }
        }
        report["provisioningProfile"] = embeddedProfile()
        report["webAssembly"] = webAssemblyCheck()
        try M0Files.writeJSON("capabilities.json", report)
        model.status = "Capabilities written to Documents/m0/capabilities.json"
    }

    /// Whether a bare JSContext (no JIT on a device) has WebAssembly: Code Mode's QuickJS sandbox needs it.
    private static func webAssemblyCheck() -> [String: Any] {
        guard let context = JSContext() else { return ["ok": false, "error": "no JSContext"] }
        // (module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
        let result = context.evaluateScript("""
        (() => {
          if (typeof WebAssembly !== "object") return { ok: false, typeof: typeof WebAssembly };
          try {
            const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11]);
            const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {});
            return { ok: instance.exports.add(2, 3) === 5, typeof: "object", async: typeof WebAssembly.instantiate };
          } catch (error) {
            return { ok: false, typeof: "object", error: String(error) };
          }
        })()
        """)
        return (result?.toDictionary() as? [String: Any]) ?? ["ok": false, "error": String(describing: context.exception)]
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Writes a snapshot the widget displays, which proves the container is shared across processes.
    private static func appGroupCheck() -> [String: Any] {
        guard let url = SharedContainer.url else { return ["ok": false, "error": "containerURL returned nil"] }
        do {
            let snapshot = try SharedContainer.directory("snapshots").appendingPathComponent("m0.json")
            let payload = ["writtenAt": ISO8601DateFormatter().string(from: .now), "by": "capabilities check"]
            try JSONSerialization.data(withJSONObject: payload).write(to: snapshot, options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
            return ["ok": true, "path": url.path]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private static func keychainCheck() -> [String: Any] {
        let store = KeychainKeys(service: "dev.jcdiv47.pidurable.capability-check")
        do {
            try store.setKey("probe", for: "probe")
            let readBack = store.apiKey(for: "probe")
            let group = accessGroup(service: store.service, account: "probe")
            try store.removeKey(for: "probe")
            // With keychain-access-groups set, new items go to its first group (the shared one).
            return ["ok": readBack == "probe", "defaultAccessGroup": group ?? "?"]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private static func accessGroup(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String
    }

    private static func liveActivityCheck() async -> [String: Any] {
        var result: [String: Any] = ["enabled": ActivityAuthorizationInfo().areActivitiesEnabled]
        do {
            let activity = try Activity.request(
                attributes: PiRunAttributes(title: "M0 capability check"),
                content: .init(state: .init(status: "checking"), staleDate: nil)
            )
            result["requested"] = true
            try? await Task.sleep(for: .seconds(1))
            await activity.end(.init(state: .init(status: "done"), staleDate: nil), dismissalPolicy: .immediate)
        } catch {
            result["requested"] = false
            result["error"] = String(describing: error)
        }
        return result
    }

    private static func backgroundCheck() -> [String: Any] {
        var result: [String: Any] = [
            "modes": Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? [],
        ]
        func submit(_ name: String, _ request: BGTaskRequest) {
            do {
                try BGTaskScheduler.shared.submit(request)
                result[name] = "submitted"
            } catch {
                result[name] = String(describing: error)
            }
        }
        submit("appRefresh", BGAppRefreshTaskRequest(identifier: BackgroundWork.refresh))
        submit("processing", BGProcessingTaskRequest(identifier: BackgroundWork.processing))
        // iOS 26 continued processing: registered on demand, runs right away with system UI.
        let identifier = BackgroundWork.runPrefix + "m0"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            task.progress.totalUnitCount = 1
            task.progress.completedUnitCount = 1
            task.setTaskCompleted(success: true)
        }
        result["continuedProcessingRegistered"] = registered
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Pi M0", subtitle: "Capability check")
        request.strategy = .fail
        submit("continuedProcessing", request)
        return result
    }

    /// Device builds embed the provisioning profile; its entitlements are what the personal team granted.
    private static func embeddedProfile() -> Any {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return "none (simulator builds carry no profile)" }
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound ..< end.upperBound], format: nil) as? [String: Any]
        else { return "unparseable" }
        return [
            "name": plist["Name"] as? String ?? "?",
            "teamName": plist["TeamName"] as? String ?? "?",
            "expires": (plist["ExpirationDate"] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "?",
            "entitlements": jsonSafe(plist["Entitlements"]),
        ]
    }

    private static func jsonSafe(_ value: Any?) -> Any {
        switch value {
        case let dictionary as [String: Any]: dictionary.mapValues { jsonSafe($0) }
        case let array as [Any]: array.map { jsonSafe($0) }
        case let value as String: value
        case let value as Bool: value
        case let value as NSNumber: value
        case let value?: String(describing: value)
        case nil: NSNull()
        }
    }

    // MARK: Conformance (the same suites `swift test` runs, here in the app's own JSC)

    static func conformance(_ model: AppModel) async throws {
        guard let url = Bundle.main.url(forResource: "pi-conformance", withExtension: "js") else {
            throw JSRuntimeError("pi-conformance.js is missing from the app bundle")
        }
        let runtime = JSRuntime(options: .init(onLog: AppModel.forwardLog))
        try await runtime.evaluate(String(contentsOf: url, encoding: .utf8), sourceURL: url)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conformance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runs: [(String, [any Sendable])] = [
            ("PiConformance.runStorage", [directory.path]),
            ("PiConformance.runFacade", [directory.path]),
            ("PiConformance.runPolyfills", []),
        ]
        var suites: [[String: Any]] = []
        for (function, arguments) in runs {
            model.status = "Running \(function)…"
            let json = try await runtime.callAsync(function, arguments)
            guard var report = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { continue }
            // Keep only failing cases; passing ones are just names.
            report["cases"] = (report["cases"] as? [[String: Any]])?.filter { $0["ok"] as? Bool == false }
            suites.append(report)
        }
        runtime.terminate()
        let pass = !suites.isEmpty && suites.allSatisfy { ($0["failed"] as? Int) == 0 }
        try M0Files.writeJSON("conformance.json", [
            "pass": pass,
            "environment": isSimulator ? "simulator" : "device",
            "JSC_useJIT": ProcessInfo.processInfo.environment["JSC_useJIT"] ?? "unset",
            "suites": suites,
        ])
        model.status = pass ? "Conformance passed" : "Conformance FAILED"
    }

    // MARK: Measurements

    static func measure(_ model: AppModel, launchedAtMs: Double) async throws {
        let bundle = try AppModel.bundleURL
        var report: [String: Any] = [
            "environment": isSimulator ? "simulator" : "device",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "JSC_useJIT": ProcessInfo.processInfo.environment["JSC_useJIT"] ?? "unset",
            "processStartToAppModelMs": launchedAtMs,
            "bundleBytes": (try? FileManager.default.attributesOfItem(atPath: bundle.path)[.size] as? Int) ?? -1,
            "footprintBeforeLoadMB": ProcessMetrics.footprintMB(),
        ]
        let harness = try await PiHarness.load(bundle: bundle, options: .init(keys: model.keys, onLog: AppModel.forwardLog))
        model.adopt(harness)
        report["evaluateMs"] = harness.evaluateMs
        report["footprintAfterEvaluateMB"] = ProcessMetrics.footprintMB()

        let useProvider = model.hasKey && UserDefaults.standard.string(forKey: "PiMeasureProvider") != "faux"
        let database = M0Files.url("measure.sqlite")
        M0Files.removeDatabase(database)
        let opened = try await harness.open(.init(
            dbPath: database.path,
            provider: useProvider ? model.provider : "faux",
            modelId: useProvider ? model.modelId : "killtest",
            keyedProviders: Array(AppModel.defaultModels.keys),
            toolMs: 50
        ))
        report["openMs"] = opened.openMs
        report["coldStartToHarnessOpenMs"] = ProcessMetrics.msSinceProcessStart()
        report["footprintAfterOpenMB"] = ProcessMetrics.footprintMB()
        model.status = "Measuring: idle…"
        try await Task.sleep(for: .seconds(3))
        report["footprintIdleMB"] = ProcessMetrics.footprintMB()
        report["jsLoopBenchmarkMs"] = try await jsBenchmark(harness.runtime)

        model.status = "Measuring: run…"
        let sampler = FootprintSampler()
        let busyBefore = harness.runtime.busyTime
        sampler.start()
        let prompt = "Write about 300 words on why on-device AI agents must survive being killed by the OS. Plain prose, no lists."
        let json = try await harness.runtime.callAsync("PiRuntime.ask", [prompt, "measure-1"])
        let (peak, samples) = sampler.stop()
        let jsBusyMs = (harness.runtime.busyTime - busyBefore).milliseconds
        report["jsBusyDuringRunMs"] = jsBusyMs
        if let run = try? JSONDecoder().decode(PiHarness.AskResult.self, from: Data(json.utf8)), let tokens = run.outputTokens, tokens > 0 {
            report["jsBusyMsPerToken"] = jsBusyMs / Double(tokens)
            report["jsBusyShareOfRun"] = jsBusyMs / run.totalMs
        }
        report["runProvider"] = useProvider ? "\(model.provider)/\(model.modelId)" : "faux/killtest (no key)"
        report["run"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? json
        report["footprintPeakDuringRunMB"] = peak
        report["footprintSamples"] = samples
        report["footprintAfterRunMB"] = ProcessMetrics.footprintMB()
        model.status = "Measuring: Code Mode…"
        report["codeMode"] = try await codeModeBenchmark(harness)
        report["footprintAfterCodeModeMB"] = ProcessMetrics.footprintMB()
        try M0Files.writeJSON("metrics.json", report)
        model.status = "Measurements written to Documents/m0/metrics.json"
    }

    /// Code Mode scripts through the offline model's "code" cue: the first compiles QuickJS (a cold start), the second
    /// is warm, the third computes, which shows QuickJS's speed when it is itself interpreted (no JIT on a device).
    private static func codeModeBenchmark(_ harness: PiHarness) async throws -> [String: Any] {
        struct Meta: Decodable { let id: Int }
        struct Frame: Decodable {
            struct Item: Decodable { let kind: String; let toolName: String?; let text: String?; let isError: Bool? }
            let items: [Item]
        }
        let scripts = [
            ("first", "return 1"),
            ("warm", "return 2"),
            ("loop1e5", "let s = 0; for (let i = 0; i < 1e5; i++) s += i % 7; text(String(s))"),
        ]
        var results: [String: Any] = [:]
        for (index, (name, code)) in scripts.enumerated() {
            let meta: Meta = try await harness.call("PiRuntime.createConversation", ["scripted", "assistant"])
            let start = ContinuousClock.now
            try await harness.perform("PiRuntime.send", [meta.id, "code \(code)", "measure-code-\(index)"])
            var result: Frame.Item?
            while result == nil, ContinuousClock.now - start < .seconds(120) {
                try await Task.sleep(for: .milliseconds(50))
                let frame: Frame = try await harness.call("PiRuntime.transcript", [meta.id])
                result = frame.items.first { $0.kind == "toolResult" && $0.toolName == "codemode" }
            }
            results[name] = [
                "totalMs": (ContinuousClock.now - start).milliseconds,
                "isError": result?.isError ?? true,
                "output": String((result?.text ?? "no result in 120 s").prefix(300)),
            ]
        }
        return results
    }

    /// A CPU-bound loop plus JSON work: shows the cost of running without the JIT.
    private static func jsBenchmark(_ runtime: JSRuntime) async throws -> Double {
        try await runtime.perform { context in
            let start = ContinuousClock.now
            context.evaluateScript("""
            (() => {
              let s = 0;
              for (let i = 0; i < 3e6; i++) s += i % 7;
              const rows = [];
              for (let i = 0; i < 2e4; i++) rows.push({ i, text: "row " + i, tags: ["a", "b"] });
              return JSON.parse(JSON.stringify(rows)).length + s;
            })()
            """)
            return (ContinuousClock.now - start).milliseconds
        }
    }
}

/// Counts tool markers emitted by `js/src/killtest.ts`.
final class MarkerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ json: String) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              event["type"] as? String == "marker",
              let tool = event["tool"] as? String, let name = event["event"] as? String
        else { return }
        lock.withLock { counts["\(tool).\(name)", default: 0] += 1 }
    }

    func count(_ tool: String, _ event: String) -> Int {
        lock.withLock { counts["\(tool).\(event)"] ?? 0 }
    }
}
