const std = @import("std");
const TypeId = @import("builtin").TypeId;
const assert = std.debug.assert;
const time = std.os.time;
const warn = std.debug.warn;

const Timer = time.Timer;

const BenchFn = fn (*Context) void;

pub const Context = struct {
    timer: Timer,
    iter: u32,
    state: State,
    nanoseconds: u64,

    const State = enum {
        None,
        Heating,
        Running,
        Finished,
    };

    pub fn init() Context {
        return Context{.timer = Timer.start() catch unreachable, .iter = 0, .state = State.None, .nanoseconds = 0};
    }

    pub fn run(self: *Context) bool {
        switch (self.state) {
            State.None => {
                self.state = State.Heating;
                self.timer.reset();
                return true;
            },
            State.Heating => {
                const elapsed = self.timer.read();
                self.nanoseconds += elapsed;
                if (self.nanoseconds >= time.second / 8) {
                    // Caches should be hot
                    self.state = State.Running;
                    self.nanoseconds = 0;
                }
                self.timer.reset();
                return true;
            },
            State.Running => {
                // TODO check if reading timings is costly, maybe first
                // estimating a number of runs based on heating phase would
                // be more efficient and less disturbing for the benchmark
                self.nanoseconds += self.timer.read();
                self.iter += 1;
                if (self.nanoseconds >= time.second / 2) {
                    self.state = State.Finished;
                    return false;
                }
                else {
                    self.timer.reset();
                    return true;
                }
            },
            State.Finished => unreachable
        }
    }

    pub fn averageTime(self: *Context, unit: u64) f32 {
        assert(self.state == State.Finished);
        return @intToFloat(f32, self.nanoseconds / unit) / @intToFloat(f32, self.iter);
    }
};

pub fn benchmark(name: comptime []const u8, f: BenchFn) void {
    var ctx = Context.init();
    @noInlineCall(f, &ctx);
    var unit: u64 = undefined;
    var unit_name: []const u8 = undefined;
    switch (ctx.averageTime(1)) {
        0...time.microsecond => {
            unit = 1;
            unit_name = "ns";
        },
        time.microsecond + 1...time.millisecond => {
            unit = time.microsecond;
            unit_name = "us";
        },
        else => {
            unit = time.millisecond;
            unit_name = "ms";
        }
    }
    warn("{}: avg {.3}{} ({} iterations)\n", name, ctx.averageTime(unit), unit_name, ctx.iter);
}

fn benchArgFn(comptime argType: type) type {
    return fn (*Context, argType) void;
}

fn argTypeFromFn(comptime f: var) type {
    comptime const F = @typeOf(f);
    comptime if (@typeId(F) != TypeId.Fn) {
        @compileError("Argument must be a function.");
    };

    return @typeInfo(F).Fn.args[1].arg_type.?;
}

pub fn benchmarkArgs(comptime name: []const u8, comptime f: var, comptime args: []const argTypeFromFn(f)) void {
    inline for (args) |a| {
        var ctx = Context.init();
        @noInlineCall(f, &ctx, a);
        var unit: u64 = undefined;
        var unit_name: []const u8 = undefined;
        switch (ctx.averageTime(1)) {
            0...time.microsecond => {
                unit = 1;
                unit_name = "ns";
            },
            time.microsecond + 1...time.millisecond => {
                unit = time.microsecond;
                unit_name = "us";
            },
            else => {
                unit = time.millisecond;
                unit_name = "ms";
            }
        }
        warn("{}<{}>: avg {.3}{} ({} iterations)\n", name, if (@typeOf(a) == type) @typeName(a) else a, ctx.averageTime(unit), unit_name, ctx.iter);
    }
}

pub fn doNotOptimize(value: var) void {
    // LLVM triggers an assert if we pass non-trivial types as inputs for the
    // asm volatile expression.
    // Workaround until asm support is better on Zig's end.
    const T = @typeOf(value);
    const typeId = @typeId(T);
    switch (typeId) {
        TypeId.Bool, TypeId.Int, TypeId.Float => {
            asm volatile ("" : : [_]"r,m"(value) : "memory");
        },
        TypeId.Optional => {
            if (value) |v| doNotOptimize(v);
        },
        TypeId.Struct => {
            inline for (comptime std.meta.fields(T)) |field| {
                doNotOptimize(@field(value, field.name));
            }
        },
        TypeId.Type, TypeId.Void, TypeId.NoReturn, TypeId.ComptimeFloat,
        TypeId.ComptimeInt, TypeId.Undefined, TypeId.Null, TypeId.Fn,
        TypeId.Namespace, TypeId.BoundFn => @compileError("doNotOptimize makes no sense for " ++ @tagName(typeId)),
        else => @compileError("doNotOptimize is not implemented for " ++ @tagName(typeId))
    }
}

pub fn clobberMemory() void {
    asm volatile ("" : : : "memory");
}

test "benchmark" {
    const benchSleep57 = struct {
        fn benchSleep57(ctx: *Context) void {
            while (ctx.run()) {
                time.sleep(57 * time.millisecond);
            }
        }
    }.benchSleep57;

    std.debug.warn("\n");
    benchmark("Sleep57", benchSleep57);
}

test "benchmarkArgs" {
    const benchSleep = struct {
        fn benchSleep(ctx: *Context, ms: u32) void {
            while (ctx.run()) {
                time.sleep(ms * time.millisecond);
            }
        }
    }.benchSleep;

    std.debug.warn("\n");
    benchmarkArgs("Sleep", benchSleep, []const u32{20, 30, 57});
}

test "benchmarkArgs types" {
    const benchMin = struct {
        fn benchMin(ctx: *Context, comptime intType: type) void {
            while (ctx.run()) {
                time.sleep(std.math.min(37, 48) * time.millisecond);
            }
        }
    }.benchMin;

    std.debug.warn("\n");
    benchmarkArgs("Min", benchMin, []type{u32, u64});
}