usingnamespace @import("./imports.zig");

const std = @import("std");
const main = @import("root");
const is_bindgen = std.meta.trait.hasDecls(main, .{"bindgen"});
const hasRef = std.meta.trait.hasField("ref");
const StaticExport = @import("./static_export.zig");
const Sizes = @import("./sizes.zig");

pub fn Shimmer(comptime _namespace: []const u8, comptime _name: []const u8, comptime Parent: type) type {
    return struct {
        pub const namespace = _namespace;
        pub const name = _name;

        fn toCppType(comptime FromType: ?type) ?type {
            return comptime brk: {
                var NewReturnType = FromType orelse c_void;

                if (NewReturnType == c_void) {
                    break :brk FromType;
                }

                var ReturnTypeInfo: std.builtin.TypeInfo = @typeInfo(FromType orelse c_void);

                if (ReturnTypeInfo == .Pointer and NewReturnType != *c_void) {
                    NewReturnType = ReturnTypeInfo.Pointer.child;
                    ReturnTypeInfo = @typeInfo(NewReturnType);
                }

                switch (ReturnTypeInfo) {
                    .Union,
                    .Struct,
                    .Enum,
                    => {
                        if (@hasDecl(ReturnTypeInfo, "Type")) {
                            break :brk NewReturnType;
                        }
                    },
                    else => {},
                }

                break :brk FromType;
            };
        }

        pub const size_of_symbol = std.fmt.comptimePrint("{s}__{s}_object_size_", .{ namespace, name });
        pub const byte_size = brk: {
            const identifier = std.fmt.comptimePrint("{s}__{s}", .{ namespace, name });
            if (@hasDecl(Sizes, identifier)) {
                break :brk @field(Sizes, identifier);
            } else {
                break :brk 0;
            }
        };
        pub const Bytes = [byte_size]u8;

        pub inline fn getConvertibleType(comptime ZigType: type) type {
            if (@typeInfo(ZigType) == .Struct) {
                const Struct: std.builtin.TypeInfo.Struct = ChildType.Struct;
                for (Struct.fields) |field| {
                    if (std.mem.eql(u8, field.name, "ref")) {
                        return field.field_type;
                    }
                }
            }

            return ZigType;
        }

        fn pointerChild(comptime Type: type) type {
            if (@typeInfo(Type) == .Pointer) {
                return @typeInfo(Type).Pointer.child_type;
            }

            return Type;
        }

        pub inline fn toZigType(comptime ZigType: type, comptime CppType: type, value: CppType) *ZigType {
            if (comptime hasRef(ZigType)) {
                // *WTF::String => Wtf.String{ = value}, via casting instead of copying
                if (comptime @typeInfo(CppType) == .Pointer and @typeInfo(ZigType) != .Pointer) {
                    return @bitCast(ZigType, @ptrToInt(value));
                }
            }

            return @as(ZigType, value);
        }

        pub fn symbolName(comptime typeName: []const u8) []const u8 {
            return comptime std.fmt.comptimePrint("{s}__{s}__{s}", .{ namespace, name, typeName });
        }

        pub fn exportFunctions(comptime Functions: anytype) [std.meta.fieldNames(@TypeOf(Functions)).len]StaticExport {
            const FunctionsType = @TypeOf(Functions);
            return comptime brk: {
                var functions: [std.meta.fieldNames(FunctionsType).len]StaticExport = undefined;
                for (std.meta.fieldNames(FunctionsType)) |fn_name, i| {
                    const Function = @TypeOf(@field(Functions, fn_name));
                    if (@typeInfo(Function) != .Fn) {
                        @compileError("Expected " ++ @typeName(Parent) ++ "." ++ @typeName(Function) ++ " to be a function but received " ++ @tagName(@typeInfo(Function)));
                    }
                    var Fn: std.builtin.TypeInfo.Fn = @typeInfo(Function).Fn;
                    if (Fn.calling_convention != .C) {
                        @compileError("Expected " ++ @typeName(Parent) ++ "." ++ @typeName(Function) ++ " to have a C Calling Convention.");
                    }

                    const export_name = symbolName(fn_name);
                    functions[i] = StaticExport{
                        .Type = Function,
                        .symbol_name = export_name,
                        .local_name = fn_name,
                        .Parent = Parent,
                    };
                }

                break :brk functions;
            };
        }

        pub inline fn zigFn(comptime typeName: []const u8, args: anytype) (@typeInfo(@TypeOf(@field(Parent, typeName))).Fn.return_type orelse void) {
            const identifier = symbolName(typeName);
            const func = comptime @typeInfo(Parent).Struct.fields[std.meta.fieldIndex(Parent, typeName)].field_type;
            const ReturnType = comptime @typeInfo(func).Fn.return_type orelse c_void;

            const Func: type = comptime brk: {
                var FuncType: std.builtin.TypeInfo = @typeInfo(@TypeOf(func));
                var Fn: std.builtin.TypeInfo.Fn = FuncType.Fn;

                Fn.calling_convention = std.builtin.CallingConvention.C;
                Fn.return_type = toCppType(Fn.return_type);

                const ArgsType = @TypeOf(args);
                for (std.meta.fieldNames(args)) |field, i| {
                    Fn.args[i] = std.builtin.TypeInfo.FnArg{
                        .is_generic = false,
                        .is_noalias = false,
                        .arg_type = @typeInfo(ArgsType).fields[i].field_type,
                    };
                }
                FuncType.Fn = Fn;
                break :brk @Type(FuncType);
            };

            comptime @export(Func, .{ .name = identifier });
            unreachable;
        }

        pub inline fn cppFn(comptime typeName: []const u8, args: anytype) (ret: {
            if (!@hasDecl(Parent, typeName)) {
                @compileError(@typeName(Parent) ++ " is missing cppFn: " ++ typeName);
            }
            break :ret std.meta.declarationInfo(Parent, typeName).data.Fn.return_type;
        }) {
            if (comptime is_bindgen) {
                unreachable;
            } else {
                const identifier = comptime std.fmt.comptimePrint("{s}__{s}__{s}", .{ namespace, name, typeName });
                const func = comptime @typeInfo(Parent).Struct.fields[std.meta.fieldIndex(Parent, typeName)].field_type;
                const ReturnType = comptime @typeInfo(func).Fn.return_type orelse c_void;

                const Func: type = comptime brk: {
                    var FuncType: std.builtin.TypeInfo = @typeInfo(@TypeOf(func));
                    var Fn: std.builtin.TypeInfo.Fn = FuncType.Fn;

                    Fn.calling_convention = std.builtin.CallingConvention.C;
                    Fn.return_type = toCppType(Fn.return_type);

                    const ArgsType = @TypeOf(args);
                    for (std.meta.fieldNames(args)) |field, i| {
                        Fn.args[i] = std.builtin.TypeInfo.FnArg{
                            .is_generic = false,
                            .is_noalias = false,
                            .arg_type = @typeInfo(ArgsType).fields[i].field_type,
                        };
                    }
                    FuncType.Fn = Fn;
                    break :brk @Type(FuncType);
                };
                const Outgoing = comptime @extern(Func, std.builtin.ExternOptions{ .name = identifier });

                return toZigType(
                    ReturnType,
                    @typeInfo(Func).Fn.return_type orelse void,
                    @call(.{}, Outgoing, args),
                );
            }
        }
    };
}

pub const JSObject = packed struct {
    pub const shim = Shimmer("JSC", "JSObject", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<JavaScriptCore/JSObject.h>";
    pub const name = "JSC::JSObject";
    pub const namespace = "JSC";

    pub fn putAtIndex(this: *JSObject, globalThis: *JSGlobalObject, property_name: *PropertyName, i: u32) bool {
        return cppFn("putAtIndex", .{
            this,
            property_name,
            i,
        });
    }

    pub fn getArrayLength(this: *JSObject) usize {
        return cppFn("getArrayLength", .{
            this,
        });
    }

    pub fn getAtIndex(this: *JSObject, globalThis: *JSGlobalObject, property_name: *PropertyName, i: u32) JSValue {
        return cppFn("getAtIndex", .{
            this,
            property_name,
            i,
        });
    }

    pub const Extern = [_][]const u8{
        "getArrayLength",
        "getAtIndex",
        "putAtIndex",
    };
};

pub const PropertyNameArray = packed struct {
    pub const shim = Shimmer("JSC", "PropertyNameArray", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<JavaScriptCore/PropertyNameArray.h>";
    pub const name = "JSC::PropertyNameArray";
    pub const namespace = "JSC";

    pub fn length(this: *PropertyNameArray) usize {
        return cppFn("length", .{this});
    }

    pub fn next(this: *PropertyNameArray, i: usize) ?*const PropertyName {
        return cppFn("next", .{ this, i });
    }

    pub fn release(this: *PropertyNameArray) void {
        return cppFn("release", .{this});
    }

    pub const Extern = [_][]const u8{ "length", "release", "next" };
};

pub const JSCell = packed struct {
    pub const shim = Shimmer("JSC", "JSCell", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<JavaScriptCore/JSCell.h>";
    pub const name = "JSC::JSCell";
    pub const namespace = "JSC";

    const CellType = enum(u8) { _ };

    pub fn getObject(this: *JSCell) *JSObject {
        return shim.cppFn("getObject", .{this});
    }

    pub fn getString(this: *JSCell, globalObject: *JSGlobalObject) *String {
        return shim.cppFn("getString", .{ this, globalObject });
    }

    pub fn getType(this: *JSCell) u8 {
        return shim.cppFn("getType", .{
            this,
        });
    }

    pub const Extern = [_][]const u8{ "getObject", "getString", "getType" };
};

pub const JSString = packed struct {
    pub const shim = Shimmer("JSC", "JSString", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<JavaScriptCore/JSString.h>";
    pub const name = "JSC::JSString";
    pub const namespace = "JSC";

    pub fn getObject(this: *JSString) *JSObject {
        return shim.cppFn("getObject", .{this});
    }

    pub fn eql(this: *const JSString, other: *const JSString) bool {
        return shim.cppFn("eql", .{ this, other });
    }

    pub fn value(this: *JSString, globalObject: *JSGlobalObject) *String {
        return shim.cppFn("value", .{ this, globalObject });
    }

    pub fn length(this: *const JSString) usize {
        return shim.cppFn("length", .{
            this,
        });
    }

    pub fn is8Bit(this: *const JSString) bool {
        return shim.cppFn("is8Bit", .{
            this,
        });
    }

    pub fn createFromOwnedString(vm: *VM, str: *const StringImpl) bool {
        return shim.cppFn("createFromOwnedString", .{
            vm, str,
        });
    }

    pub fn createFromString(vm: *VM, str: *const StringImpl) bool {
        return shim.cppFn("createFromString", .{
            vm, str,
        });
    }

    pub const Extern = [_][]const u8{ "getObject", "eql", "value", "length", "is8Bit", "createFromOwnedString", "createFromString" };
};

pub const JSPromiseRejectionOperation = enum(u32) {
    Reject = 0,
    Handle = 1,
};

pub const ZigGlobalObject = packed struct {
    pub const shim = Shimmer("Zig", "GlobalObject", @This());
    bytes: shim.Bytes,
    pub const Type = *c_void;
    pub const name = "Zig::GlobalObject";
    pub const include = "\"ZigGlobalObject.h\"";
    pub const namespace = shim.namespace;

    pub fn import(global: *JSGlobalObject, loader: *JSModuleLoader, string: *JSString, value: JSValue, origin: *const SourceOrigin) callconv(.C) *JSInternalPromise {
        if (comptime is_bindgen) {
            unreachable;
        }
    }
    pub fn resolve(global: *JSGlobalObject, loader: *JSModuleLoader, string: *JSString, value: JSValue, origin: *const SourceOrigin) callconv(.C) *const Identifier {
        if (comptime is_bindgen) {
            unreachable;
        }
    }
    pub fn fetch(global: *JSGlobalObject, loader: *JSModuleLoader, value1: JSValue, value2: JSValue, value3: JSValue) callconv(.C) *JSInternalPromise {
        if (comptime is_bindgen) {
            unreachable;
        }
    }
    pub fn eval(global: *JSGlobalObject, loader: *JSModuleLoader, key: JSValue, moduleRecordValue: JSValue, scriptFetcher: JSValue, awaitedValue: JSValue, resumeMode: JSValue) callconv(.C) JSValue {
        if (comptime is_bindgen) {
            unreachable;
        }
    }
    pub fn reportUncaughtException(global: *JSGlobalObject, promise: *JSPromise, rejection: JSPromiseRejectionOperation) callconv(.C) JSValue {
        if (comptime is_bindgen) {
            unreachable;
        }
    }

    pub const Export = shim.exportFunctions(.{
        .@"import" = import,
        .@"resolve" = resolve,
        .@"fetch" = fetch,
        .@"eval" = eval,
        .@"reportUncaughtException" = reportUncaughtException,
    });

    comptime {
        @export(import, .{ .name = Export[0].symbol_name });
        @export(resolve, .{ .name = Export[1].symbol_name });
        @export(fetch, .{ .name = Export[2].symbol_name });
        @export(eval, .{ .name = Export[3].symbol_name });
        @export(reportUncaughtException, .{ .name = Export[4].symbol_name });
    }
};

pub const DefaultGlobal = packed struct {
    pub const shim = Shimmer("Wundle", "DefaultGlobal", @This());
    bytes: shim.Bytes,
    pub const include = "\"DefaultGlobal.h\"";
    pub const name = "Wundle::DefaultGlobal";
    pub const namespace = "Wundle";

    pub fn getWrapper(this: *DefaultGlobal) *c_void {
        return shim.cppFn("getWrapper", .{this});
    }

    pub fn create(this: *DefaultGlobal, wrapper_ptr: *c_void) *DefaultGlobal {
        return shim.cppFn("create", .{ this, wrapper_ptr });
    }

    pub const Extern = [_][]const u8{ "getWrapper", "create" };
};

pub const JSModuleLoader = packed struct {
    pub const shim = Shimmer("JSC", "JSModuleLoader", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<JavaScriptCore/JSModuleLoader.h>";
    pub const name = "JSC::JSModuleLoader";
    pub const namespace = "JSC";

    pub fn dependencyKeysIfEvaluated(this: *JSModuleLoader, globalObject: *JSGlobalObject, moduleRecord: *JSModuleRecord) *JSValue {
        return shim.cppFn("dependencyKeysIfEvaluated", .{ this, globalObject, moduleRecord });
    }

    pub const Extern = [_][]const u8{
        "dependencyKeysIfEvaluated",
    };
};

pub const JSModuleRecord = packed struct {
    pub const shim = Shimmer("JSC", "JSModuleRecord", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<JavaScriptCore/JSModuleRecord.h>";
    pub const name = "JSC::JSModuleRecord";
    pub const namespace = "JSC";

    pub fn sourceCode(this: *JSModuleRecord) *const SourceCode {
        return shim.cppFn("sourceCode", .{
            this,
        });
    }

    pub const Extern = [_][]const u8{
        "sourceCode",
    };
};

pub const JSPromise = packed struct {
    pub const shim = Shimmer("JSC", "JSPromise", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<JavaScriptCore/JSPromise.h>";
    pub const name = "JSC::JSPromise";
    pub const namespace = "JSC";

    pub const Status = enum(u32) {
        Pending = 0, // Making this as 0, so that, we can change the status from Pending to others without masking.
        Fulfilled = 1,
        Rejected = 2,
    };

    pub fn status(this: *const JSPromise, vm: *VM) Status {
        return shim.cppFn("status", .{ this, vm });
    }
    pub fn result(this: *const JSPromise, vm: *VM) JSValue {
        return cppFn("result", .{ this, vm });
    }
    pub fn isHandled(this: *const JSPromise, vm: *VM) bool {
        return cppFn("isHandled", .{ this, vm });
    }

    pub fn rejectWithCaughtException(this: *JSPromise, globalObject: *JSGlobalObject, scope: ThrowScope) void {
        return cppFn("rejectWithCaughtException", .{ this, globalObject, scope });
    }

    pub fn resolvedPromise(globalThis: *JSGlobalObject, value: JSValue) *JSPromise {
        return cppFn("resolvedPromise", .{ .globalThis = globalThis, .value = value });
    }
    pub fn rejectedPromise(globalThis: *JSGlobalObject, value: JSValue) *JSPromise {
        return cppFn("rejectedPromise", .{ .globalThis = globalThis, .value = value });
    }

    pub fn resolve(globalThis: *JSGlobalObject, value: JSValue) void {
        cppFn("resolve", .{ .globalThis = globalThis, .value = value });
    }
    pub fn reject(this: *JSPromise, globalThis: *JSGlobalObject, value: JSValue) void {
        cppFn("reject", .{ .this = this, .globalThis = globalThis, .value = value });
    }
    pub fn rejectAsHandled(this: *JSPromise, globalThis: *JSGlobalObject, value: JSValue) void {
        cppFn("rejectAsHandled", .{ .this = this, .globalThis = globalThis, .value = value });
    }
    pub fn rejectException(this: *JSPromise, globalThis: *JSGlobalObject, value: *Exception) void {
        cppFn("rejectException", .{ .this = this, .globalThis = globalThis, .value = value });
    }
    pub fn rejectAsHandledException(this: *JSPromise, globalThis: *JSGlobalObject, value: *Exception) void {
        cppFn("rejectAsHandledException", .{ .this = this, .globalThis = globalThis, .value = value });
    }

    pub fn isInternal(this: *JSPromise, vm: *VM) bool {
        return cppFn("isInternal", .{ this, vm });
    }

    pub fn createDeferred(globalThis: *JSGlobalObject, resolved: *JSFunction, rejected: *JSFunction, exception: *Exception) *JSPromise {
        return cppFn("createDeferred", .{
            .globalThis = globalThis,
            .resolve = resolved,
            .reject = rejected,
            .exception = exception,
        });
    }

    pub const Extern = [_][]const u8{ "rejectWithCaughtException", "status", "result", "isHandled", "resolvedPromise", "rejectedPromise", "resolve", "reject", "rejectAsHandled", "rejectException", "rejectAsHandledException", "isInternal", "createDeferred" };
};

pub const JSInternalPromise = JSPromise;

// SourceProvider.h
pub const SourceType = enum(u8) {
    Program = 0,
    Module = 1,
    WebAssembly = 2,
};

pub const SourceOrigin = packed struct {
    pub const shim = Shimmer("JSC", "SourceOrigin", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<JavaScriptCore/SourceOrigin.h>";
    pub const name = "JSC::SourceOrigin";
    pub const namespace = "JSC";

    pub fn fromURL(url: *const URL) *const SourceOrigin {
        return cppFn("fromURL", .{url});
    }

    pub const Extern = [_][]const u8{
        "fromURL",
    };
};

pub const SourceCode = packed struct {
    pub const shim = Shimmer("JSC", "SourceCode", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<JavaScriptCore/SourceProvider.h>";
    pub const name = "JSC::SourceCode";
    pub const namespace = "JSC";

    pub fn fromString(source: *const String, origin: *const SourceOrigin, filename: *String, source_type: SourceType) *const SourceCode {
        return cppFn("fromString", .{ source, origin, filename, source_type });
    }

    pub const Extern = [_][]const u8{
        "fromString",
    };
};

pub const JSFunction = packed struct {
    pub const shim = Shimmer("JSC", "JSFunction", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<JavaScriptCore/JSFunction.h>";
    pub const name = "JSC::JSFunction";
    pub const namespace = "JSC";

    pub fn createFromSourceCode(source: *SourceCode, origin: *SourceOrigin, exception: ?*Exception) *JSFunction {
        return cppFn("createFromSourceCode", .{ source, origin, exception });
    }
    pub fn createFromNative(
        vm: *VM,
        globalthis: *JSGlobalObject,
        argument_count: u32,
        name_: *String,
        func: *c_void,
    ) *JSFunction {
        return cppFn("createFromNative", .{ vm, globalthis, argument_count, name_, func });
    }
    pub fn getName(this: *JSFunction, vm: *VM) *String {
        return cppFn("getName", .{ this, vm });
    }
    pub fn displayName(this: *JSFunction, vm: *VM) *String {
        return cppFn("displayName", .{ this, vm });
    }
    pub fn calculatedDisplayName(this: *JSFunction, vm: *VM) *String {
        return cppFn("calculatedDisplayName", .{ this, vm });
    }
    pub fn toString(this: *JSFunction, globalThis: *JSGlobalObject) *const JSString {
        return cppFn("toString", .{ this, globalThis });
    }

    pub fn callWithArgumentsAndThis(
        function: *JSFunction,
        thisValue: JSValue,
        globalThis: *JSGlobalObject,
        arguments_ptr: [*]JSValue,
        arguments_len: usize,
        exception: *?*Exception,
        error_message: ?*const u8,
    ) JSValue {
        return cppFn("callWithArgumentsAndThis", .{
            function,
            globalThis,
            thisValue,
            arguments_ptr,
            arguments_len,
            exception,
            error_message,
        });
    }

    pub fn callWithArguments(
        function: *JSFunction,
        globalThis: *JSGlobalObject,
        arguments_ptr: [*]JSValue,
        arguments_len: usize,
        exception: *?*Exception,
        error_message: ?*const u8,
    ) JSValue {
        return cppFn("callWithArguments", .{ function, globalThis, arguments_ptr, arguments_len, exception, exception, error_message });
    }

    pub fn callWithThis(
        function: *JSFunction,
        globalThis: *JSGlobalObject,
        thisValue: JSValue,
        exception: *?*Exception,
        error_message: ?*const u8,
    ) JSValue {
        return cppFn("callWithArguments", .{
            function,
            globalThis,
            thisValue,
            exception,
            error_message,
        });
    }

    pub fn callWithoutAnyArgumentsOrThis(
        function: *JSFunction,
        globalThis: *JSGlobalObject,
        exception: *?*Exception,
        error_message: ?*const u8,
    ) JSValue {
        return cppFn("callWithoutAnyArgumentsOrThis", .{ function, globalThis, exception, exception, error_message });
    }

    pub fn constructWithArgumentsAndNewTarget(
        function: *JSFunction,
        newTarget: JSValue,
        globalThis: *JSGlobalObject,
        arguments_ptr: [*]JSValue,
        arguments_len: usize,
        exception: *?*Exception,
        error_message: ?*const u8,
    ) JSValue {
        return cppFn("constructWithArgumentsAndNewTarget", .{
            function,
            globalThis,
            newTarget,
            arguments_ptr,
            arguments_len,
            exception,
            error_message,
        });
    }

    pub fn constructWithArguments(
        function: *JSFunction,
        globalThis: *JSGlobalObject,
        arguments_ptr: [*]JSValue,
        arguments_len: usize,
        exception: *?*Exception,
        error_message: ?*const u8,
    ) JSValue {
        return cppFn("constructWithArguments", .{ function, globalThis, arguments_ptr, arguments_len, exception, exception, error_message });
    }

    pub fn constructWithNewTarget(
        function: *JSFunction,
        globalThis: *JSGlobalObject,
        newTarget: JSValue,
        exception: *?*Exception,
        error_message: ?*const u8,
    ) JSValue {
        return cppFn("constructWithArguments", .{
            function,
            globalThis,
            newTarget,
            exception,
            error_message,
        });
    }

    pub fn constructWithoutAnyArgumentsOrNewTarget(
        function: *JSFunction,
        globalThis: *JSGlobalObject,
        exception: *?*Exception,
        error_message: ?*const u8,
    ) JSValue {
        return cppFn("constructWithoutAnyArgumentsOrNewTarget", .{ function, globalThis, exception, exception, error_message });
    }

    pub const Extern = [_][]const u8{
        "fromString",
        "createFromSourceCode",
        "createFromNative",
        "getName",
        "displayName",
        "calculatedDisplayName",
        "callWithArgumentsAndThis",
        "callWithArguments",
        "callWithThis",
        "callWithoutAnyArgumentsOrThis",
        "constructWithArgumentsAndNewTarget",
        "constructWithArguments",
        "constructWithNewTarget",
        "constructWithoutAnyArgumentsOrNewTarget",
    };
};

pub const JSGlobalObject = packed struct {
    pub const shim = Shimmer("JSC", "JSGlobalObject", @This());
    bytes: shim.Bytes,

    pub const include = "<JavaScriptCore/JSGlobalObject.h>";
    pub const name = "JSC::JSGlobalObject";
    pub const namespace = "JSC";

    pub const ErrorType = enum(u8) {
        Error = 0,
        EvalError = 1,
        RangeError = 2,
        ReferenceError = 3,
        SyntaxError = 4,
        TypeError = 5,
        URIError = 6,
        AggregateError = 7,
        OutOfMemoryError = 8,
    };

    pub fn createError(globalObject: *JSGlobalObject, error_type: ErrorType, message: *String) *JSObject {
        return cppFn("createError", .{ globalObject, @enumToInt(error_type), message });
    }

    pub fn throwError(
        globalObject: *JSGlobalObject,
        err: *JSObject,
    ) *JSObject {
        return cppFn("throwError", .{
            globalObject,
            err,
        });
    }

    const cppFn = shim.cppFn;

    pub fn objectPrototype(this: *JSGlobalObject) *ObjectPrototype {
        return cppFn("objectPrototype", .{this});
    }
    pub fn functionPrototype(this: *JSGlobalObject) *FunctionPrototype {
        return cppFn("functionPrototype", .{this});
    }
    pub fn arrayPrototype(this: *JSGlobalObject) *ArrayPrototype {
        return cppFn("arrayPrototype", .{this});
    }
    pub fn booleanPrototype(this: *JSGlobalObject) *JSObject {
        return cppFn("booleanPrototype", .{this});
    }
    pub fn stringPrototype(this: *JSGlobalObject) *StringPrototype {
        return cppFn("stringPrototype", .{this});
    }
    pub fn numberPrototype(this: *JSGlobalObject) *JSObject {
        return cppFn("numberPrototype", .{this});
    }
    pub fn bigIntPrototype(this: *JSGlobalObject) *BigIntPrototype {
        return cppFn("bigIntPrototype", .{this});
    }
    pub fn datePrototype(this: *JSGlobalObject) *JSObject {
        return cppFn("datePrototype", .{this});
    }
    pub fn symbolPrototype(this: *JSGlobalObject) *JSObject {
        return cppFn("symbolPrototype", .{this});
    }
    pub fn regExpPrototype(this: *JSGlobalObject) *RegExpPrototype {
        return cppFn("regExpPrototype", .{this});
    }
    pub fn errorPrototype(this: *JSGlobalObject) *JSObject {
        return cppFn("errorPrototype", .{this});
    }
    pub fn iteratorPrototype(this: *JSGlobalObject) *IteratorPrototype {
        return cppFn("iteratorPrototype", .{this});
    }
    pub fn asyncIteratorPrototype(this: *JSGlobalObject) *AsyncIteratorPrototype {
        return cppFn("asyncIteratorPrototype", .{this});
    }
    pub fn generatorFunctionPrototype(this: *JSGlobalObject) *GeneratorFunctionPrototype {
        return cppFn("generatorFunctionPrototype", .{this});
    }
    pub fn generatorPrototype(this: *JSGlobalObject) *GeneratorPrototype {
        return cppFn("generatorPrototype", .{this});
    }
    pub fn asyncFunctionPrototype(this: *JSGlobalObject) *AsyncFunctionPrototype {
        return cppFn("asyncFunctionPrototype", .{this});
    }
    pub fn arrayIteratorPrototype(this: *JSGlobalObject) *ArrayIteratorPrototype {
        return cppFn("arrayIteratorPrototype", .{this});
    }
    pub fn mapIteratorPrototype(this: *JSGlobalObject) *MapIteratorPrototype {
        return cppFn("mapIteratorPrototype", .{this});
    }
    pub fn setIteratorPrototype(this: *JSGlobalObject) *SetIteratorPrototype {
        return cppFn("setIteratorPrototype", .{this});
    }
    pub fn mapPrototype(this: *JSGlobalObject) *JSObject {
        return cppFn("mapPrototype", .{this});
    }
    pub fn jsSetPrototype(this: *JSGlobalObject) *JSObject {
        return cppFn("jsSetPrototype", .{this});
    }
    pub fn promisePrototype(this: *JSGlobalObject) *JSPromisePrototype {
        return cppFn("promisePrototype", .{this});
    }
    pub fn asyncGeneratorPrototype(this: *JSGlobalObject) *AsyncGeneratorPrototype {
        return cppFn("asyncGeneratorPrototype", .{this});
    }
    pub fn asyncGeneratorFunctionPrototype(this: *JSGlobalObject) *AsyncGeneratorFunctionPrototype {
        return cppFn("asyncGeneratorFunctionPrototype", .{this});
    }

    pub fn vm(this: *JSGlobalObject) *VM {
        return cppFn("vm", .{this});
    }

    pub const Extern = [_][]const u8{
        "objectPrototype",
        "functionPrototype",
        "arrayPrototype",
        "booleanPrototype",
        "stringPrototype",
        "numberPrototype",
        "bigIntPrototype",
        "datePrototype",
        "symbolPrototype",
        "regExpPrototype",
        "errorPrototype",
        "iteratorPrototype",
        "asyncIteratorPrototype",
        "generatorFunctionPrototype",
        "generatorPrototype",
        "asyncFunctionPrototype",
        "arrayIteratorPrototype",
        "mapIteratorPrototype",
        "setIteratorPrototype",
        "mapPrototype",
        "jsSetPrototype",
        "promisePrototype",
        "asyncGeneratorPrototype",
        "asyncGeneratorFunctionPrototype",
        "vm",
        "createError",
        "throwError",
    };
};

fn _JSCellStub(comptime str: []const u8) type {
    if (is_bindgen) {
        return opaque {
            pub const name = "JSC::" ++ str ++ "";
        };
    } else {
        return struct {};
    }
}

fn _Wundle(comptime str: []const u8) type {
    if (is_bindgen) {
        return opaque {
            pub const name = "Wundle::" ++ str ++ "";
        };
    } else {
        return struct {};
    }
}

fn _WTF(comptime str: []const u8) type {
    if (is_bindgen) {
        return opaque {
            pub const name = "WTF::" ++ str ++ "";
        };
    } else {
        return struct {};
    }
}

pub const URL = packed struct {
    pub const shim = Shimmer("WTF", "URL", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<wtf/URL.h>";
    pub const name = "WTF::URL";
    pub const namespace = "WTF";

    pub fn fromString(base: String, relative: String) URL {
        return cppFn("fromString", .{ base, relative });
    }

    pub fn fromFileSystemPath(file_system_path: StringView) URL {
        return cppFn("fromFileSystemPath", .{file_system_path});
    }

    pub fn isEmpty(this: *const URL) bool {
        return cppFn("isEmpty", .{this});
    }
    pub fn isValid(this: *const URL) bool {
        return cppFn("isValid", .{this});
    }

    pub fn protocol(this: *URL) StringView {
        return cppFn("protocol", .{this});
    }
    pub fn encodedUser(this: *URL) StringView {
        return cppFn("encodedUser", .{this});
    }
    pub fn encodedPassword(this: *URL) StringView {
        return cppFn("encodedPassword", .{this});
    }
    pub fn host(this: *URL) StringView {
        return cppFn("host", .{this});
    }
    pub fn path(this: *URL) StringView {
        return cppFn("path", .{this});
    }
    pub fn lastPathComponent(this: *URL) StringView {
        return cppFn("lastPathComponent", .{this});
    }
    pub fn query(this: *URL) StringView {
        return cppFn("query", .{this});
    }
    pub fn fragmentIdentifier(this: *URL) StringView {
        return cppFn("fragmentIdentifier", .{this});
    }
    pub fn queryWithLeadingQuestionMark(this: *URL) StringView {
        return cppFn("queryWithLeadingQuestionMark", .{this});
    }
    pub fn fragmentIdentifierWithLeadingNumberSign(this: *URL) StringView {
        return cppFn("fragmentIdentifierWithLeadingNumberSign", .{this});
    }
    pub fn stringWithoutQueryOrFragmentIdentifier(this: *URL) StringView {
        return cppFn("stringWithoutQueryOrFragmentIdentifier", .{this});
    }
    pub fn stringWithoutFragmentIdentifier(this: *URL) String {
        return cppFn("stringWithoutFragmentIdentifier", .{this});
    }
    pub fn protocolHostAndPort(this: *URL) String {
        return cppFn("protocolHostAndPort", .{this});
    }
    pub fn hostAndPort(this: *URL) String {
        return cppFn("hostAndPort", .{this});
    }
    pub fn user(this: *URL) String {
        return cppFn("user", .{this});
    }
    pub fn password(this: *URL) String {
        return cppFn("password", .{this});
    }
    pub fn fileSystemPath(this: *URL) String {
        return cppFn("fileSystemPath", .{this});
    }

    pub fn setProtocol(this: *URL, protocol_value: StringView) void {
        return cppFn("setProtocol", .{ this, protocol_value });
    }
    pub fn setHost(this: *URL, host_value: StringView) void {
        return cppFn("setHost", .{ this, host_value });
    }
    pub fn setHostAndPort(this: *URL, host_and_port_value: StringView) void {
        return cppFn("setHostAndPort", .{ this, host_and_port_value });
    }
    pub fn setUser(this: *URL, user_value: StringView) void {
        return cppFn("setUser", .{ this, user_value });
    }
    pub fn setPassword(this: *URL, password_value: StringView) void {
        return cppFn("setPassword", .{ this, password_value });
    }
    pub fn setPath(this: *URL, path_value: StringView) void {
        return cppFn("setPath", .{ this, path_value });
    }
    pub fn setQuery(this: *URL, query_value: StringView) void {
        return cppFn("setQuery", .{ this, query_value });
    }

    pub fn truncatedForUseAsBase(
        this: *URL,
    ) URL {
        return cppFn("truncatedForUseAsBase", .{
            this,
        });
    }
    pub const Extern = [_][]const u8{ "fromFileSystemPath", "fromString", "isEmpty", "isValid", "protocol", "encodedUser", "encodedPassword", "host", "path", "lastPathComponent", "query", "fragmentIdentifier", "queryWithLeadingQuestionMark", "fragmentIdentifierWithLeadingNumberSign", "stringWithoutQueryOrFragmentIdentifier", "stringWithoutFragmentIdentifier", "protocolHostAndPort", "hostAndPort", "user", "password", "fileSystemPath", "setProtocol", "setHost", "setHostAndPort", "setUser", "setPassword", "setPath", "setQuery", "truncatedForUseAsBase" };
};

pub const String = packed struct {
    pub const shim = Shimmer("WTF", "String", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;
    pub const include = "<wtf/text/WTFString.h>";
    pub const name = "WTF::String";
    pub const namespace = "WTF";

    pub fn createWithoutCopyingFromPtr(str: [*]const u8, len: usize) String {
        return cppFn("createWithoutCopyingFromPtr", .{ str, len });
    }

    pub fn createFromExternalString(str: ExternalStringImpl) String {
        return cppFn("createFromExternalString", .{str});
    }

    pub fn createWithoutCopying(str: []const u8) String {
        return @call(.{ .modifier = .always_inline }, createWithoutCopyingFromPtr, .{ str.ptr, str.len });
    }

    pub fn is8Bit(this: *String) bool {
        return cppFn("is8Bit", .{this});
    }
    pub fn is16Bit(this: *String) bool {
        return cppFn("is16Bit", .{this});
    }
    pub fn isExternal(this: *String) bool {
        return cppFn("isExternal", .{this});
    }
    pub fn isStatic(this: *String) bool {
        return cppFn("isStatic", .{this});
    }
    pub fn isEmpty(this: *String) bool {
        return cppFn("isEmpty", .{this});
    }
    pub fn length(this: *String) usize {
        return cppFn("length", .{this});
    }
    pub fn characters8(this: *String) [*]const u8 {
        return cppFn("characters8", .{this});
    }
    pub fn characters16(this: *String) [*]const u16 {
        return cppFn("characters16", .{this});
    }

    pub fn eqlString(this: *String, other: *const String) bool {
        return cppFn("eqlString", .{ this, other });
    }

    pub fn eqlSlice(this: *String, other: [*]const u8, other_len: usize) bool {
        return cppFn("eqlSlice", .{ this, other, other_len });
    }

    pub fn impl(
        this: *String,
    ) *const StringImpl {
        return cppFn("impl", .{
            this,
        });
    }

    pub const slice = SliceFn(@This());

    pub const Extern = [_][]const u8{
        "is8Bit",
        "is16Bit",
        "isExternal",
        "isStatic",
        "isEmpty",
        "length",
        "characters8",
        "characters16",
        "createWithoutCopyingFromPtr",
        "eqlString",
        "eqlSlice",
        "impl",
        "createFromExternalString",
    };
};

pub const JSValue = enum(i64) {
    _,

    pub const shim = Shimmer("JSC", "JSValue", @This());
    pub const is_pointer = false;
    pub const Type = i64;
    const cppFn = shim.cppFn;

    pub const include = "<JavaScriptCore/JSValue.h>";
    pub const name = "JSC::JSValue";
    pub const namespace = "JSC";

    pub fn jsNumber(number: anytype) JSValue {
        return switch (@TypeOf(number)) {
            f64 => @call(.{ .modifier = .always_inline }, jsNumberFromDouble, .{number}),
            u8 => @call(.{ .modifier = .always_inline }, jsNumberFromChar, .{number}),
            u16 => @call(.{ .modifier = .always_inline }, jsNumberFromU16, .{number}),
            i32 => @call(.{ .modifier = .always_inline }, jsNumberFromInt32, .{number}),
            i64 => @call(.{ .modifier = .always_inline }, jsNumberFromInt64, .{number}),
            u64 => @call(.{ .modifier = .always_inline }, jsNumberFromUint64, .{number}),
            else => @compileError("Type transformation missing for number of type: " ++ @typeName(@TypeOf(number))),
        };
    }

    pub fn jsNull() JSValue {
        return cppFn("jsNull", .{});
    }
    pub fn jsUndefined() JSValue {
        return cppFn("jsUndefined", .{});
    }
    pub fn jsTDZValue() JSValue {
        return cppFn("jsTDZValue", .{});
    }
    pub fn jsBoolean(i: bool) JSValue {
        return cppFn("jsBoolean", .{i});
    }
    pub fn jsDoubleNumber(i: f64) JSValue {
        return cppFn("jsDoubleNumber", .{i});
    }

    pub fn jsNumberFromDouble(i: f64) JSValue {
        return cppFn("jsNumberFromDouble", .{i});
    }
    pub fn jsNumberFromChar(i: u8) JSValue {
        return cppFn("jsNumberFromChar", .{i});
    }
    pub fn jsNumberFromU16(i: u16) JSValue {
        return cppFn("jsNumberFromU16", .{i});
    }
    pub fn jsNumberFromInt32(i: i32) JSValue {
        return cppFn("jsNumberFromInt32", .{i});
    }
    pub fn jsNumberFromInt64(i: i64) JSValue {
        return cppFn("jsNumberFromInt64", .{i});
    }
    pub fn jsNumberFromUint64(i: u64) JSValue {
        return cppFn("jsNumberFromUint64", .{i});
    }

    pub fn isUndefined(this: JSValue) bool {
        return cppFn("isUndefined", .{this});
    }
    pub fn isNull(this: JSValue) bool {
        return cppFn("isNull", .{this});
    }
    pub fn isUndefinedOrNull(this: JSValue) bool {
        return cppFn("isUndefinedOrNull", .{this});
    }
    pub fn isBoolean(this: JSValue) bool {
        return cppFn("isBoolean", .{this});
    }
    pub fn isAnyInt(this: JSValue) bool {
        return cppFn("isAnyInt", .{this});
    }
    pub fn isUInt32AsAnyInt(this: JSValue) bool {
        return cppFn("isUInt32AsAnyInt", .{this});
    }
    pub fn isInt32AsAnyInt(this: JSValue) bool {
        return cppFn("isInt32AsAnyInt", .{this});
    }
    pub fn isNumber(this: JSValue) bool {
        return cppFn("isNumber", .{this});
    }
    pub fn isError(this: JSValue) bool {
        return cppFn("isError", .{this});
    }
    pub fn isString(this: JSValue) bool {
        return cppFn("isString", .{this});
    }
    pub fn isBigInt(this: JSValue) bool {
        return cppFn("isBigInt", .{this});
    }
    pub fn isHeapBigInt(this: JSValue) bool {
        return cppFn("isHeapBigInt", .{this});
    }
    pub fn isBigInt32(this: JSValue) bool {
        return cppFn("isBigInt32", .{this});
    }
    pub fn isSymbol(this: JSValue) bool {
        return cppFn("isSymbol", .{this});
    }
    pub fn isPrimitive(this: JSValue) bool {
        return cppFn("isPrimitive", .{this});
    }
    pub fn isGetterSetter(this: JSValue) bool {
        return cppFn("isGetterSetter", .{this});
    }
    pub fn isCustomGetterSetter(this: JSValue) bool {
        return cppFn("isCustomGetterSetter", .{this});
    }
    pub fn isObject(this: JSValue) bool {
        return cppFn("isObject", .{this});
    }

    pub fn isCell(this: JSValue) bool {
        return cppFn("isCell", .{this});
    }

    pub fn asCell(this: JSValue) *JSCell {
        return cppFn("asCell", .{this});
    }

    pub fn isCallable(this: JSValue) bool {
        return cppFn("isCallable", .{this});
    }

    // On exception, this returns the empty string.
    pub fn toString(this: JSValue, globalThis: *JSGlobalObject) *JSString {
        return cppFn("toString", .{ this, globalThis });
    }

    // On exception, this returns null, to make exception checks faster.
    pub fn toStringOrNull(this: JSValue, globalThis: *JSGlobalObject) *JSString {
        return cppFn("toStringOrNull", .{ this, globalThis });
    }
    pub fn toPropertyKey(this: JSValue, globalThis: *JSGlobalObject) Identifier {
        return cppFn("toPropertyKey", .{ this, globalThis });
    }
    pub fn toPropertyKeyValue(this: JSValue, globalThis: *JSGlobalObject) JSValue {
        return cppFn("toPropertyKeyValue", .{ this, globalThis });
    }
    pub fn toObject(this: JSValue, globalThis: *JSGlobalObject) *JSObject {
        return cppFn("toObject", .{ this, globalThis });
    }

    pub fn getPrototype(this: JSValue, globalObject: *JSGlobalObject) JSValue {
        return cppFn("getPrototype", .{ this, globalObject });
    }

    pub fn eqlValue(this: JSValue, other: JSValue) bool {
        return cppFn("eqlValue", .{ this, other });
    }

    pub fn eqlCell(this: JSValue, other: *JSCell) bool {
        return cppFn("eqlCell", .{ this, other });
    }

    pub fn asString(this: JSValue) *JSString {
        return cppFn("asString", .{
            this,
        });
    }

    pub fn asObject(this: JSValue) JSObject {
        return cppFn("asObject", .{
            this,
        });
    }

    pub fn asNumber(this: JSValue) f64 {
        return cppFn("asNumber", .{
            this,
        });
    }

    pub fn encode(this: JSValue) u64 {
        return cppFn("encode", .{
            this,
        });
    }

    pub const Extern = [_][]const u8{ "hasProperty", "getPropertyNames", "getDirect", "putDirect", "get", "getIfExists", "encode", "asString", "asObject", "asNumber", "isError", "jsNull", "jsUndefined", "jsTDZValue", "jsBoolean", "jsDoubleNumber", "jsNumberFromDouble", "jsNumberFromChar", "jsNumberFromU16", "jsNumberFromInt32", "jsNumberFromInt64", "jsNumberFromUint64", "isUndefined", "isNull", "isUndefinedOrNull", "isBoolean", "isAnyInt", "isUInt32AsAnyInt", "isInt32AsAnyInt", "isNumber", "isString", "isBigInt", "isHeapBigInt", "isBigInt32", "isSymbol", "isPrimitive", "isGetterSetter", "isCustomGetterSetter", "isObject", "isCell", "asCell", "toString", "toStringOrNull", "toPropertyKey", "toPropertyKeyValue", "toObject", "toString", "getPrototype", "getPropertyByPropertyName", "eqlValue", "eqlCell" };
};

pub const PropertyName = packed struct {
    pub const shim = Shimmer("JSC", "PropertyName", @This());
    bytes: shim.Bytes,

    const cppFn = shim.cppFn;

    pub const include = "<JavaScriptCore/PropertyName.h>";
    pub const name = "JSC::PropertyName";
    pub const namespace = "JSC";

    pub fn eqlToPropertyName(property_name: *PropertyName, other: *const PropertyName) bool {
        return cppFn("eqlToPropertyName", .{ property_name, other });
    }

    pub fn eqlToIdentifier(property_name: *PropertyName, other: *const Identifier) bool {
        return cppFn("eqlToIdentifier", .{ property_name, other });
    }

    pub fn publicName(property_name: *PropertyName) ?*const StringImpl {
        return cppFn("publicName", .{
            property_name,
        });
    }

    pub fn uid(property_name: *PropertyName) ?*const StringImpl {
        return cppFn("uid", .{
            property_name,
        });
    }

    pub const Extern = [_][]const u8{ "eqlToPropertyName", "eqlToIdentifier", "publicName", "uid" };
};

pub const Exception = packed struct {
    pub const shim = Shimmer("JSC", "Exception", @This());
    bytes: shim.Bytes,
    pub const Type = JSObject;
    const cppFn = shim.cppFn;

    pub const include = "<JavaScriptCore/Exception.h>";
    pub const name = "JSC::Exception";
    pub const namespace = "JSC";

    pub const StackCaptureAction = enum(u8) {
        CaptureStack = 0,
        DoNotCaptureStack = 1,
    };

    pub fn create(globalObject: *JSGlobalObject, object: *JSObject, stack_capture: StackCaptureAction) *Exception {
        return cppFn(
            "create",
            .{ globalObject, object, @enumToInt(stack_capture) },
        );
    }

    pub const Extern = [_][]const u8{
        "create",
    };
};

pub const JSLock = packed struct {
    pub const shim = Shimmer("JSC", "Exception", @This());
    bytes: shim.Bytes,

    const cppFn = shim.cppFn;

    pub const include = "<JavaScriptCore/JSLock.h>";
    pub const name = "JSC::JSLock";
    pub const namespace = "JSC";

    pub fn lock(this: *JSLock) void {
        return cppFn("lock", .{this});
    }
    pub fn unlock(this: *JSLock) void {
        return cppFn("unlock", .{this});
    }

    pub const Extern = [_][]const u8{ "lock", "unlock" };
};

pub const VM = packed struct {
    pub const shim = Shimmer("JSC", "VM", @This());
    bytes: shim.Bytes,

    const cppFn = shim.cppFn;

    pub const include = "<JavaScriptCore/VM.h>";
    pub const name = "JSC::VM";
    pub const namespace = "JSC";

    pub const HeapType = enum(u8) {
        SmallHeap = 0,
        LargeHeap = 1,
    };
    pub fn create(heap_type: HeapType) *VM {
        return cppFn("create", .{@enumToInt(heap_type)});
    }

    pub fn deinit(vm: *VM, global_object: *JSGlobalObject) void {
        return cppFn("deinit", .{ vm, global_object });
    }

    pub fn setExecutionForbidden(vm: *VM, forbidden: bool) void {
        cppFn("setExecutionForbidden", .{ vm, forbidden });
    }

    pub fn executionForbidden(vm: *VM) bool {
        return cppFn("executionForbidden", .{
            vm,
        });
    }

    pub fn isEntered(vm: *VM) bool {
        return cppFn("isEntered", .{
            vm,
        });
    }

    pub fn throwError(vm: *VM, global_object: *JSGlobalObject, scope: *ThrowScope, message: [*]const u8, len: usize) bool {
        return cppFn("throwError", .{
            vm,
            scope,
            global_object,

            message,
            len,
        });
    }

    pub fn apiLock(vm: *VM) *JSLock {
        return cppFn("apiLock", .{
            vm,
        });
    }

    pub fn drainMicrotasks(
        vm: *VM,
    ) void {
        return cppFn("drainMicrotasks", .{
            vm,
        });
    }

    pub const Extern = [_][]const u8{ "apiLock", "create", "deinit", "setExecutionForbidden", "executionForbidden", "isEntered", "throwError", "drainMicrotasks" };
};

pub const ThrowScope = packed struct {
    pub const shim = Shimmer("JSC", "ThrowScope", @This());
    bytes: shim.Bytes,

    const cppFn = shim.cppFn;

    pub const include = "<JavaScriptCore/ThrowScope.h>";
    pub const name = "JSC::ThrowScope";
    pub const namespace = "JSC";

    pub fn declare(
        vm: *VM,
        function_name: [*]u8,
        file: [*]u8,
        line: usize,
    ) ThrowScope {
        return cppFn("declare", .{ vm, file, line });
    }

    pub fn release(this: *ThrowScope) void {
        return cppFn("release", .{this});
    }

    pub fn exception(this: *ThrowScope) ?*Exception {
        return cppFn("exception", .{this});
    }

    pub fn clearException(this: *ThrowScope) void {
        return cppFn("clearException", .{this});
    }

    pub const Extern = [_][]const u8{
        "declare",
        "release",
        "exception",
        "clearException",
    };
};

pub const CatchScope = packed struct {
    pub const shim = Shimmer("JSC", "CatchScope", @This());
    bytes: shim.Bytes,

    const cppFn = shim.cppFn;

    pub const include = "<JavaScriptCore/CatchScope.h>";
    pub const name = "JSC::CatchScope";
    pub const namespace = "JSC";

    pub fn declare(
        vm: *VM,
        function_name: [*]u8,
        file: [*]u8,
        line: usize,
    ) CatchScope {
        return cppFn("declare", .{ vm, file, line });
    }

    pub fn exception(this: *CatchScope) ?*Exception {
        return cppFn("exception", .{this});
    }

    pub fn clearException(this: *CatchScope) void {
        return cppFn("clearException", .{this});
    }

    pub const Extern = [_][]const u8{
        "declare",
        "exception",
        "clearException",
    };
};

pub const CallFrame = packed struct {
    pub const shim = Shimmer("JSC", "CallFrame", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;

    pub const include = "<JavaScriptCore/CallFrame.h>";
    pub const name = "JSC::CallFrame";
    pub const namespace = "JSC";

    pub inline fn argumentsCount(call_frame: *const CallFrame) usize {
        return cppFn("argumentsCount", .{
            call_frame,
        });
    }
    pub inline fn uncheckedArgument(call_frame: *const CallFrame, i: u16) JSValue {
        return cppFn("uncheckedArgument", .{ call_frame, i });
    }
    pub inline fn argument(call_frame: *const CallFrame, i: u16) JSValue {
        return cppFn("argument", .{
            call_frame,
        });
    }
    pub inline fn thisValue(call_frame: *const CallFrame) ?JSValue {
        return cppFn("thisValue", .{
            call_frame,
        });
    }
    pub inline fn newTarget(call_frame: *const CallFrame) ?JSValue {
        return cppFn("newTarget", .{
            call_frame,
        });
    }
    pub inline fn jsCallee(call_frame: *const CallFrame) *JSObject {
        return cppFn("jsCallee", .{
            call_frame,
        });
    }
    pub const Extern = [_][]const u8{ "argumentsCount", "uncheckedArgument", "argument", "thisValue", "newTarget", "jsCallee" };
};

// pub const WellKnownSymbols = packed struct {
//     pub const shim = Shimmer("JSC", "CommonIdentifiers", @This());

//
//

//     pub const include = "<JavaScriptCore/CommonIdentifiers.h>";
//     pub const name = "JSC::CommonIdentifiers";
//     pub const namespace = "JSC";

//     pub var hasthis: *const Identifier = shim.cppConst(Identifier, "hasInstance");
//     pub var isConcatSpreadable: Identifier = shim.cppConst(Identifier, "isConcatSpreadable");
//     pub var asyncIterator: Identifier = shim.cppConst(Identifier, "asyncIterator");
//     pub var iterator: Identifier = shim.cppConst(Identifier, "iterator");
//     pub var match: Identifier = shim.cppConst(Identifier, "match");
//     pub var matchAll: Identifier = shim.cppConst(Identifier, "matchAll");
//     pub var replace: Identifier = shim.cppConst(Identifier, "replace");
//     pub var search: Identifier = shim.cppConst(Identifier, "search");
//     pub var species: Identifier = shim.cppConst(Identifier, "species");
//     pub var split: Identifier = shim.cppConst(Identifier, "split");
//     pub var toPrimitive: Identifier = shim.cppConst(Identifier, "toPrimitive");
//     pub var toStringTag: Identifier = shim.cppConst(Identifier, "toStringTag");
//     pub var unscopable: Identifier = shim.cppConst(Identifier, "unscopabl");

// };

pub const EncodedJSValue = enum(i64) {
    _,

    pub const shim = Shimmer("JSC", "EncodedJSValue", @This());

    pub const Type = u64;
    const cppFn = shim.cppFn;

    pub const include = "<JavaScriptCore/EncodedJSValue.h>";
    pub const name = "JSC::EncodedJSValue";
    pub const namespace = "JSC";
};

pub const Identifier = packed struct {
    pub const shim = Shimmer("JSC", "Identifier", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;

    pub const include = "<JavaScriptCore/Identifier.h>";
    pub const name = "JSC::Identifier";
    pub const namespace = "JSC";

    pub fn fromString(vm: *VM, other: *const String) Identifier {
        return cppFn("fromString", .{ vm, other });
    }

    pub fn fromSlice(vm: *VM, ptr: [*]const u8, len: usize) Identifier {
        return cppFn("fromSlice", .{ vm, ptr, len });
    }

    pub fn fromUid(vm: *VM, other: *const StringImpl) Identifier {
        return cppFn("fromString", .{ vm, other });
    }

    pub fn deinit(this: *const Identifier) void {
        return cppFn("deinit", .{this});
    }

    pub fn toString(identifier: *const Identifier) String {
        return cppFn("toString", .{identifier});
    }

    pub fn length(identifier: *const Identifier) usize {
        return cppFn("length", .{identifier});
    }

    pub fn isNull(this: *const Identifier) bool {
        return cppFn("isNull", .{this});
    }
    pub fn isEmpty(this: *const Identifier) bool {
        return cppFn("isEmpty", .{this});
    }
    pub fn isSymbol(this: *const Identifier) bool {
        return cppFn("isSymbol", .{this});
    }
    pub fn isPrivateName(this: *const Identifier) bool {
        return cppFn("isPrivateName", .{this});
    }

    pub fn eqlIdent(this: *const Identifier, other: *const Identifier) bool {
        return cppFn("eqlIdent", .{ this, other });
    }

    pub fn neqlIdent(this: *const Identifier, other: *const Identifier) bool {
        return cppFn("neqlIdent", .{ this, other });
    }

    pub fn eqlStringImpl(this: *const Identifier, other: *const StringImpl) bool {
        return cppFn("eqlStringImpl", .{ this, other });
    }

    pub fn neqlStringImpl(this: *const Identifier, other: *const StringImpl) bool {
        return cppFn("neqlStringImpl", .{ this, other });
    }

    pub fn eqlUTF8(this: *const Identifier, other: [*]const u8, other_len: usize) bool {
        return cppFn("eqlUTF8", .{ this, other, other_len });
    }

    pub const Extern = [_][]const u8{
        "fromString",
        "fromSlice",
        "fromUid",
        "deinit",
        "toString",
        "length",
        "isNull",
        "isEmpty",
        "isSymbol",
        "isPrivateName",
        "eqlIdent",
        "neqlIdent",
        "eqlStringImpl",
        "neqlStringImpl",
        "eqlUTF8",
    };
};

const DeinitFunction = fn (ctx: *c_void, buffer: [*]u8, len: usize) callconv(.C) void;

pub const StringImpl = packed struct {
    pub const shim = Shimmer("WTF", "StringImpl", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;

    pub const include = "<wtf/text/StringImpl.h>";
    pub const name = "WTF::StringImpl";
    pub const namespace = "WTF";

    pub fn is8Bit(this: *const StringImpl) bool {
        return cppFn("is8Bit", .{this});
    }
    pub fn is16Bit(this: *const StringImpl) bool {
        return cppFn("is16Bit", .{this});
    }
    pub fn isExternal(this: *const StringImpl) bool {
        return cppFn("isExternal", .{this});
    }
    pub fn isStatic(this: *const StringImpl) bool {
        return cppFn("isStatic", .{this});
    }
    pub fn isEmpty(this: *const StringImpl) bool {
        return cppFn("isEmpty", .{this});
    }
    pub fn length(this: *const StringImpl) usize {
        return cppFn("length", .{this});
    }
    pub fn characters8(this: *const StringImpl) [*]const u8 {
        return cppFn("characters8", .{this});
    }
    pub fn characters16(this: *const StringImpl) [*]const u16 {
        return cppFn("characters16", .{this});
    }

    pub const slice = SliceFn(@This());

    pub const Extern = [_][]const u8{
        "is8Bit",
        "is16Bit",
        "isExternal",
        "isStatic",
        "isEmpty",
        "length",
        "characters8",
        "characters16",
    };
};

pub const ExternalStringImpl = packed struct {
    pub const shim = Shimmer("WTF", "ExternalStringImpl", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;

    pub const include = "<wtf/text/ExternalStringImpl.h>";
    pub const name = "WTF::ExternalStringImpl";
    pub const namespace = "WTF";

    pub fn create(ptr: [*]const u8, len: usize, deinit: DeinitFunction) ExternalStringImpl {
        return cppFn("create", .{ ptr, len, deinit });
    }

    pub fn is8Bit(this: *const ExternalStringImpl) bool {
        return cppFn("is8Bit", .{this});
    }
    pub fn is16Bit(this: *const ExternalStringImpl) bool {
        return cppFn("is16Bit", .{this});
    }
    pub fn isEmpty(this: *const ExternalStringImpl) bool {
        return cppFn("isEmpty", .{this});
    }
    pub fn length(this: *const ExternalStringImpl) usize {
        return cppFn("length", .{this});
    }
    pub fn characters8(this: *const ExternalStringImpl) [*]const u8 {
        return cppFn("characters8", .{this});
    }
    pub fn characters16(this: *const ExternalStringImpl) [*]const u16 {
        return cppFn("characters16", .{this});
    }

    pub const Extern = [_][]const u8{
        "create",
        "is8Bit",
        "is16Bit",
        "isEmpty",
        "length",
        "characters8",
        "characters16",
    };
};

pub const StringView = packed struct {
    pub const shim = Shimmer("WTF", "StringView", @This());
    bytes: shim.Bytes,
    const cppFn = shim.cppFn;

    pub const include = "<wtf/text/StringView.h>";
    pub const name = "WTF::StringView";
    pub const namespace = "WTF";

    pub fn from8Bit(ptr: [*]const u8, len: usize) StringView {
        return cppFn("from8Bit", .{ ptr, len });
    }

    pub fn fromSlice(value: []const u8) StringView {
        return from8Bit(value.ptr, value.len);
    }

    pub fn is8Bit(this: *const StringView) bool {
        return cppFn("is8Bit", .{this});
    }
    pub fn is16Bit(this: *const StringView) bool {
        return cppFn("is16Bit", .{this});
    }
    pub fn isEmpty(this: *const StringView) bool {
        return cppFn("isEmpty", .{this});
    }
    pub fn length(this: *const StringView) usize {
        return cppFn("length", .{this});
    }
    pub fn characters8(this: *const StringView) [*]const u8 {
        return cppFn("characters8", .{this});
    }
    pub fn characters16(this: *const StringView) [*]const u16 {
        return cppFn("characters16", .{this});
    }

    pub const slice = SliceFn(@This());

    pub const Extern = [_][]const u8{
        "from8Bit",
        "is8Bit",
        "is16Bit",
        "isEmpty",
        "length",
        "characters8",
        "characters16",
    };
};

pub const Cpp = struct {
    pub const Function = fn (
        globalObject: *JSGlobalObject,
        callframe: *CallFrame,
    ) *EncodedJSValue;
    pub const Getter = fn (
        globalObject: *JSGlobalObject,
        this: *EncodedJSValue,
        propertyName: *PropertyName,
    ) *EncodedJSValue;
    pub const Setter = fn (
        globalObject: *JSGlobalObject,
        this: *EncodedJSValue,
        value: EncodedJSValue,
        propertyName: *PropertyName,
    ) bool;

    pub const Tag = enum {
        Callback,
        Constructor,
        Getter,
        Setter,
    };

    pub const LUTAttribute = enum {
        Function,
        Accessor,
        CellProperty,
        ClassStructure,
        PropertyCallback,
    };

    pub const ClassDefinition = struct { name: []const u8, hostFunctions: []Host };

    pub const ZigValue = union(Tag) {
        Callback: Function,
        Constructor: Function,
        Getter: Getter,
        Setter: Setter,
    };
};
pub const Callback = struct {
    // zig: Value,
};

const _JSGlobalObject = _Wundle("JSGlobalObject");
const ObjectPrototype = _JSCellStub("ObjectPrototype");
const FunctionPrototype = _JSCellStub("FunctionPrototype");
const ArrayPrototype = _JSCellStub("ArrayPrototype");
const StringPrototype = _JSCellStub("StringPrototype");
const BigIntPrototype = _JSCellStub("BigIntPrototype");
const RegExpPrototype = _JSCellStub("RegExpPrototype");
const IteratorPrototype = _JSCellStub("IteratorPrototype");
const AsyncIteratorPrototype = _JSCellStub("AsyncIteratorPrototype");
const GeneratorFunctionPrototype = _JSCellStub("GeneratorFunctionPrototype");
const GeneratorPrototype = _JSCellStub("GeneratorPrototype");
const AsyncFunctionPrototype = _JSCellStub("AsyncFunctionPrototype");
const ArrayIteratorPrototype = _JSCellStub("ArrayIteratorPrototype");
const MapIteratorPrototype = _JSCellStub("MapIteratorPrototype");
const SetIteratorPrototype = _JSCellStub("SetIteratorPrototype");
const JSPromisePrototype = _JSCellStub("JSPromisePrototype");
const AsyncGeneratorPrototype = _JSCellStub("AsyncGeneratorPrototype");
const AsyncGeneratorFunctionPrototype = _JSCellStub("AsyncGeneratorFunctionPrototype");

pub fn SliceFn(comptime Type: type) type {
    const SliceStruct = struct {
        pub fn slice(this: *Type) []const u8 {
            if (this.isEmpty()) {
                return "";
            }

            return this.characters8()[0..this.length()];
        }
    };

    return @TypeOf(SliceStruct.slice);
}
