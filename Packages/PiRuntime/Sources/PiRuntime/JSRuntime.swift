import Foundation
import JavaScriptCore
import os
import Security

public struct JSRuntimeError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A JavaScriptCore context confined to one serial queue, with the host bindings Pi needs
/// (`globalThis.__native`, see `js/src/host/native.ts`). Every JS call runs on `queue`; JSC drains
/// the microtask queue each time control returns from JS to Swift.
public final class JSRuntime: @unchecked Sendable {
    public struct Options: Sendable {
        public var keys: ProviderKeySource?
        /// Counts keyed requests per service and month and enforces monthly caps; nil counts nothing.
        public var usage: ServiceUsage?
        public var onEvent: (@Sendable (String) -> Void)?
        public var onLog: (@Sendable (String, String) -> Void)?
        /// Answers `hostCall(name, json)` from JS (Apple tools and the like) with JSON text, off the JS queue.
        public var hostCall: HostCallHandler?
        /// Hosts served in this process instead of the network (lowercased), such as Apple Intelligence's
        /// OpenAI-compatible endpoint. `fetch` to one never leaves the device.
        public var localHosts: [String: any LocalHTTPService]
        /// Where `__native.readResource(name)` reads files by plain name, such as Code Mode's `quickjs.wasm`.
        /// `PiHarness.load` sets it to the bundle's directory when nil.
        public var resourceDirectory: URL?
        /// Whether the device is online, for model requests that wait while it is not; nil is `NetworkPath.shared`.
        public var network: (any NetworkStatus)?
        public init(
            keys: ProviderKeySource? = nil,
            usage: ServiceUsage? = nil,
            onEvent: (@Sendable (String) -> Void)? = nil,
            onLog: (@Sendable (String, String) -> Void)? = nil,
            hostCall: HostCallHandler? = nil,
            localHosts: [String: any LocalHTTPService] = [:],
            resourceDirectory: URL? = nil,
            network: (any NetworkStatus)? = nil
        ) {
            self.keys = keys
            self.usage = usage
            self.onEvent = onEvent
            self.onLog = onLog
            self.hostCall = hostCall
            self.localHosts = localHosts
            self.resourceDirectory = resourceDirectory
            self.network = network
        }
    }

    /// Handles one JS host call: a handler name and its JSON arguments, returning JSON text. A throw
    /// rejects the JS promise with the error's description.
    public typealias HostCallHandler = @Sendable (_ name: String, _ json: String) async throws -> String

    public let queue = DispatchQueue(label: "pi.js", qos: .userInitiated)
    private let logger = Logger(subsystem: "dev.pi.durable", category: "js")
    private let options: Options
    private let started = ContinuousClock.now
    private let busy = OSAllocatedUnfairLock(initialState: Duration.zero)

    /// Total time the JS queue has spent running JS (including the microtasks each call drains).
    /// Divided by output tokens it gives JS CPU per token, the cost the missing JIT adds.
    public var busyTime: Duration { busy.withLock { $0 } }

    // Confined to `queue`.
    private var context: JSContext!
    private var timers: [Int: DispatchWorkItem] = [:]
    private var databases: [Int: SQLiteConnection] = [:]
    private var nextDatabase = 1
    private var fetch: FetchBridge!

    public init(options: Options = Options()) {
        self.options = options
        queue.sync { setUp() }
    }

    deinit {
        let timers = self.timers
        for item in timers.values { item.cancel() }
    }

    // MARK: - Evaluation

    /// Evaluates a script on the JS queue. Throws the uncaught exception, if any.
    public func evaluate(_ source: String, sourceURL: URL? = nil) async throws {
        try await perform { context in
            context.exception = nil
            context.evaluateScript(source, withSourceURL: sourceURL)
            if let exception = context.exception {
                context.exception = nil
                throw JSRuntimeError(Self.describe(exception))
            }
        }
    }

    /// Runs `body` on the JS queue.
    public func perform<T: Sendable>(_ body: @escaping @Sendable (JSContext) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.timed { try body(self.context) } })
            }
        }
    }

    /// Calls `globalThis.<path>(...args)`, awaits the returned promise, and returns its value as JSON text.
    /// Arguments are passed as JSON values.
    public func callAsync(_ path: String, _ arguments: [any Sendable] = []) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async {
                let context = self.context!
                context.exception = nil
                guard let function = self.resolve(path, in: context), !function.isUndefined else {
                    return continuation.resume(throwing: JSRuntimeError("\(path) is not defined"))
                }
                let result = self.timed { function.call(withArguments: arguments) }
                if let exception = context.exception {
                    context.exception = nil
                    return continuation.resume(throwing: JSRuntimeError(Self.describe(exception)))
                }
                let promise = JSValue(object: context.objectForKeyedSubscript("Promise")!, in: context)!
                    .invokeMethod("resolve", withArguments: [result as Any])!
                let once = OSAllocatedUnfairLock(initialState: false)
                let fulfilled: @convention(block) (JSValue) -> Void = { value in
                    guard once.withLock({ let first = !$0; $0 = true; return first }) else { return }
                    let json = context.objectForKeyedSubscript("JSON")!.invokeMethod("stringify", withArguments: [value])
                    continuation.resume(returning: json?.isUndefined == false ? json!.toString() : "null")
                }
                let rejected: @convention(block) (JSValue) -> Void = { error in
                    guard once.withLock({ let first = !$0; $0 = true; return first }) else { return }
                    continuation.resume(throwing: JSRuntimeError(Self.describe(error)))
                }
                promise.invokeMethod("then", withArguments: [
                    JSValue(object: fulfilled, in: context)!,
                    JSValue(object: rejected, in: context)!,
                ])
            }
        }
    }

    private func timed<T>(_ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        defer { busy.withLock { $0 += ContinuousClock.now - start } }
        return try body()
    }

    private func resolve(_ path: String, in context: JSContext) -> JSValue? {
        var target: JSValue = context.globalObject
        var parent: JSValue = context.globalObject
        for part in path.split(separator: ".") {
            parent = target
            target = target.forProperty(String(part))
            if target.isUndefined { return nil }
        }
        // Bind so `this` is the owning object.
        return target.invokeMethod("bind", withArguments: [parent])
    }

    static func describe(_ exception: JSValue) -> String {
        let message = exception.toString() ?? "unknown error"
        if let stack = exception.forProperty("stack"), !stack.isUndefined, let text = stack.toString(), !text.isEmpty {
            return "\(message)\n\(text)"
        }
        return message
    }

    /// Stops the runtime abruptly, as if the process died: timers and requests are dropped and sqlite
    /// connections closed without letting JS clean up. Used by in-process crash tests.
    public func terminate() {
        queue.sync {
            for item in timers.values { item.cancel() }
            timers.removeAll()
            for connection in databases.values { connection.close() }
            databases.removeAll()
            fetch.cancelAll()
            context.globalObject.setValue(nil, forProperty: "__piHost")
        }
    }

    // MARK: - Setup (on queue)

    private func setUp() {
        let context = JSContext()!
        context.name = "Pi"
        self.context = context
        context.exceptionHandler = { [weak self] context, exception in
            // Keep the exception visible to the caller of evaluate/call; also log it.
            context?.exception = exception
            if let exception { self?.log("error", "Uncaught: \(Self.describe(exception))") }
        }
        context.isInspectable = true

        fetch = FetchBridge(keys: options.keys, usage: options.usage, localHosts: options.localHosts) { [weak self] id, event in
            guard let self else { return }
            self.queue.async { self.deliverFetch(id, event) }
        }

        // Unhandled promise rejections are silent: the hook for them (JSGlobalContextSetUnhandledRejectionCallback)
        // is private API. JS code reports its own failures through console/onReport instead.

        let native = JSValue(newObjectIn: context)!
        installBindings(native, context)
        context.setObject(native, forKeyedSubscript: "__native" as NSString)
        context.globalObject.setValue(context.globalObject, forProperty: "globalThis")
        context.globalObject.setValue(context.globalObject, forProperty: "self")
    }

    private func log(_ level: String, _ message: String) {
        switch level {
        case "error": logger.error("\(message, privacy: .public)")
        case "warn": logger.warning("\(message, privacy: .public)")
        case "debug": logger.debug("\(message, privacy: .public)")
        default: logger.info("\(message, privacy: .public)")
        }
        options.onLog?(level, message)
    }

    private func throwJS(_ message: String) {
        guard let context = JSContext.current() else { return }
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    private func installBindings(_ native: JSValue, _ context: JSContext) {
        func set(_ name: String, _ block: Any) {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }

        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.log(level, message)
        }
        set("log", log)

        let emit: @convention(block) (String) -> Void = { [weak self] json in
            self?.options.onEvent?(json)
        }
        set("emit", emit)

        let now: @convention(block) () -> Double = { [weak self] in
            guard let self else { return 0 }
            let elapsed = ContinuousClock.now - self.started
            return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }
        set("now", now)

        let setTimer: @convention(block) (Int, Double) -> Void = { [weak self] id, ms in
            guard let self else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.timers.removeValue(forKey: id) != nil else { return }
                self.callHost("fireTimer", [id])
            }
            self.timers[id]?.cancel()
            self.timers[id] = item
            self.queue.asyncAfter(deadline: .now() + .microseconds(Int(max(0, ms) * 1000)), execute: item)
        }
        set("setTimer", setTimer)

        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: id)?.cancel()
        }
        set("clearTimer", clearTimer)

        let randomFill: @convention(block) (JSValue) -> Void = { [weak self] array in
            let ok = JSBytes.withMutableBytes(of: array) { buffer in
                _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            if !ok { self?.throwJS("randomFill expects a typed array") }
        }
        set("randomFill", randomFill)

        let utf8Encode: @convention(block) (JSValue) -> JSValue = { value in
            let context = JSContext.current()!
            let string = value.toString() ?? ""
            var copy = string
            return copy.withUTF8 { JSBytes.uint8Array(UnsafeRawBufferPointer($0), in: context) }
        }
        set("utf8Encode", utf8Encode)

        let utf8Decode: @convention(block) (JSValue, Bool) -> JSValue = { [weak self] value, fatal in
            let context = JSContext.current()!
            guard let data = JSBytes.data(of: value) else {
                self?.throwJS("utf8Decode expects bytes")
                return JSValue(undefinedIn: context)
            }
            if fatal {
                guard let string = String(validating: data, as: UTF8.self) else { return JSValue(nullIn: context) }
                return JSValue(object: string, in: context)
            }
            return JSValue(object: String(decoding: data, as: UTF8.self), in: context)
        }
        set("utf8Decode", utf8Decode)

        let network = options.network ?? NetworkPath.shared
        let networkOnline: @convention(block) () -> Bool = { network.online }
        set("networkOnline", networkOnline)

        // Bytes of a file in `resourceDirectory`, by plain name only (no paths), or null.
        let readResource: @convention(block) (String) -> JSValue = { [weak self] name in
            let context = JSContext.current()!
            guard let directory = self?.options.resourceDirectory,
                  !name.isEmpty, !name.contains("/"), !name.hasPrefix("."),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe)
            else { return JSValue(nullIn: context) }
            return JSBytes.uint8Array(data, in: context)
        }
        set("readResource", readResource)

        let fetchStart: @convention(block) (Int, JSValue) -> Void = { [weak self] id, request in
            guard let self else { return }
            var headers: [(String, String)] = []
            if let pairs = request.forProperty("headers"), !pairs.isUndefined {
                let count = Int(pairs.forProperty("length").toInt32())
                for index in 0..<count {
                    let pair = pairs.atIndex(index)!
                    headers.append((pair.atIndex(0).toString(), pair.atIndex(1).toString()))
                }
            }
            let body = request.forProperty("body").flatMap { $0.isNull || $0.isUndefined ? nil : JSBytes.data(of: $0) }
            let redirect = request.forProperty("redirect").flatMap { $0.isString ? $0.toString() : nil } ?? "follow"
            self.fetch.start(.init(
                id: id,
                url: request.forProperty("url").toString(),
                method: request.forProperty("method").toString(),
                headers: headers,
                body: body,
                followRedirects: redirect == "follow"
            ))
        }
        set("fetchStart", fetchStart)

        let fetchCancel: @convention(block) (Int) -> Void = { [weak self] id in
            self?.fetch.cancel(id)
        }
        set("fetchCancel", fetchCancel)

        let hostCall: @convention(block) (Int, String, String) -> Void = { [weak self] id, name, json in
            guard let self else { return }
            guard let handler = self.options.hostCall else {
                self.queue.async { self.callHost("hostResult", [id, false, "No host handler for \(name)"]) }
                return
            }
            Task {
                let result: (Bool, String)
                do {
                    result = (true, try await handler(name, json))
                } catch {
                    result = (false, String(describing: error))
                }
                self.queue.async { self.callHost("hostResult", [id, result.0, result.1]) }
            }
        }
        set("hostCall", hostCall)

        installSQLite(set)
    }

    private func installSQLite(_ set: (String, Any) -> Void) {
        let open: @convention(block) (String) -> Int = { [weak self] path in
            guard let self else { return 0 }
            do {
                let connection = try SQLiteConnection(path: path)
                let handle = self.nextDatabase
                self.nextDatabase += 1
                self.databases[handle] = connection
                return handle
            } catch {
                self.throwJS(String(describing: error))
                return 0
            }
        }
        set("sqliteOpen", open)

        let exec: @convention(block) (Int, String) -> Void = { [weak self] handle, sql in
            self?.withDatabase(handle) { try $0.exec(sql) }
        }
        set("sqliteExec", exec)

        let run: @convention(block) (Int, String, JSValue) -> Int = { [weak self] handle, sql, params in
            self?.withDatabase(handle) { try $0.run(sql, params) } ?? 0
        }
        set("sqliteRun", run)

        let get: @convention(block) (Int, String, JSValue) -> JSValue = { [weak self] handle, sql, params in
            let context = JSContext.current()!
            return self?.withDatabase(handle) { try $0.get(sql, params, in: context) } ?? JSValue(undefinedIn: context)
        }
        set("sqliteGet", get)

        let all: @convention(block) (Int, String, JSValue) -> JSValue = { [weak self] handle, sql, params in
            let context = JSContext.current()!
            return self?.withDatabase(handle) { try $0.all(sql, params, in: context) } ?? JSValue(undefinedIn: context)
        }
        set("sqliteAll", all)

        let close: @convention(block) (Int) -> Void = { [weak self] handle in
            self?.databases.removeValue(forKey: handle)?.close()
        }
        set("sqliteClose", close)
    }

    private func withDatabase<T>(_ handle: Int, _ body: (SQLiteConnection) throws -> T) -> T? {
        guard let connection = databases[handle] else {
            throwJS("SQLite database is closed")
            return nil
        }
        do {
            return try body(connection)
        } catch {
            throwJS(String(describing: error))
            return nil
        }
    }

    // MARK: - Host callbacks (on queue)

    private func callHost(_ method: String, _ arguments: [Any]) {
        guard let host = context.objectForKeyedSubscript("__piHost"), !host.isUndefined else { return }
        context.exception = nil
        timed { _ = host.invokeMethod(method, withArguments: arguments) }
        if let exception = context.exception {
            context.exception = nil
            log("error", "__piHost.\(method) threw: \(Self.describe(exception))")
        }
    }

    private func deliverFetch(_ id: Int, _ event: FetchBridge.Event) {
        switch event {
        case let .response(status, statusText, headers, url):
            callHost("fetchEvent", [id, "response", ["status": status, "statusText": statusText, "headers": headers, "url": url]])
        case let .chunk(data):
            callHost("fetchEvent", [id, "chunk", JSBytes.uint8Array(data, in: context)])
        case .end:
            callHost("fetchEvent", [id, "end", NSNull()])
        case let .error(message):
            callHost("fetchEvent", [id, "error", message])
        }
    }
}
