import Foundation
import JavaScriptCore

/// Typed array helpers over the JavaScriptCore C API, which the Objective-C `JSValue` API lacks.
enum JSBytes {
    /// Copies the bytes of any typed array or ArrayBuffer value; nil for other values.
    static func data(of value: JSValue) -> Data? {
        guard let context = value.context else { return nil }
        let ctx = context.jsGlobalContextRef
        let ref = value.jsValueRef
        var exception: JSValueRef?
        let type = JSValueGetTypedArrayType(ctx, ref, &exception)
        guard exception == nil, type != kJSTypedArrayTypeNone, let object = JSValueToObject(ctx, ref, &exception) else {
            return nil
        }
        if type == kJSTypedArrayTypeArrayBuffer {
            let length = JSObjectGetArrayBufferByteLength(ctx, object, &exception)
            guard length > 0, let base = JSObjectGetArrayBufferBytesPtr(ctx, object, &exception) else { return Data() }
            return Data(bytes: base, count: length)
        }
        let length = JSObjectGetTypedArrayByteLength(ctx, object, &exception)
        guard length > 0,
              let buffer = JSObjectGetTypedArrayBuffer(ctx, object, &exception),
              let base = JSObjectGetArrayBufferBytesPtr(ctx, buffer, &exception)
        else { return Data() }
        let offset = JSObjectGetTypedArrayByteOffset(ctx, object, &exception)
        return Data(bytes: base.advanced(by: offset), count: length)
    }

    /// Fills a typed array in place; returns false when the value is not a typed array.
    static func withMutableBytes(of value: JSValue, _ body: (UnsafeMutableRawBufferPointer) -> Void) -> Bool {
        guard let context = value.context else { return false }
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        let type = JSValueGetTypedArrayType(ctx, value.jsValueRef, &exception)
        guard type != kJSTypedArrayTypeNone, type != kJSTypedArrayTypeArrayBuffer,
              let object = JSValueToObject(ctx, value.jsValueRef, &exception)
        else { return false }
        let length = JSObjectGetTypedArrayByteLength(ctx, object, &exception)
        guard length > 0,
              let buffer = JSObjectGetTypedArrayBuffer(ctx, object, &exception),
              let base = JSObjectGetArrayBufferBytesPtr(ctx, buffer, &exception)
        else { return true }
        let offset = JSObjectGetTypedArrayByteOffset(ctx, object, &exception)
        body(UnsafeMutableRawBufferPointer(start: base.advanced(by: offset), count: length))
        return true
    }

    /// A new Uint8Array holding a copy of `data`.
    static func uint8Array(_ data: Data, in context: JSContext) -> JSValue {
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let object = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array, data.count, &exception) else {
            return JSValue(undefinedIn: context)
        }
        if !data.isEmpty, let target = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) {
            data.withUnsafeBytes { source in
                target.copyMemory(from: source.baseAddress!, byteCount: data.count)
            }
        }
        return JSValue(jsValueRef: object, in: context)
    }

    static func uint8Array(_ bytes: UnsafeRawBufferPointer, in context: JSContext) -> JSValue {
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let object = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array, bytes.count, &exception) else {
            return JSValue(undefinedIn: context)
        }
        if bytes.count > 0, let target = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) {
            target.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        return JSValue(jsValueRef: object, in: context)
    }

    static func isBigInt(_ value: JSValue) -> Bool {
        guard let context = value.context else { return false }
        return JSValueIsBigInt(context.jsGlobalContextRef, value.jsValueRef)
    }

    static func bigInt(_ value: Int64, in context: JSContext) -> JSValue {
        var exception: JSValueRef?
        let ref = JSBigIntCreateWithInt64(context.jsGlobalContextRef, value, &exception)
        return JSValue(jsValueRef: ref, in: context)
    }
}
