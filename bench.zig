const std = @import("std");
const TypeInfo = @import("builtin").TypeInfo;
const assert = std.debug.assert;
const time = std.time;
const warn = std.debug.warn;

const Timer = time.Timer;

const BenchFn = fn (*Context) callconv(.Async) void;

pub const Context = struct {
    timer: Timer,
    iter: u32,
    count: u32,
    state: State,
    nanoseconds: u64,

    const HeatingTime = time.ns_per_s / 2;
    const RunTime = time.ns_per_s / 2;

    const State = enum {
        None,
        Heating,
        Running,
        Finished,
    };

    pub fn init() Context {
        return Context{ .timer = Timer.start() catch unreachable, .iter = 0, .count = 0, .state = .None, .nanoseconds = 0 };
    }

    pub fn run(self: *Context) bool {
        switch (self.state) {
            .None => {
                self.state = .Heating;
                self.timer.reset();
                return true;
            },
            .Heating => {
                self.count += 1;
                const elapsed = self.timer.read();
                if (elapsed >= HeatingTime) {
                    // Caches should be hot
                    self.count = @intCast(u32, RunTime / (HeatingTime / self.count));
                    self.state = .Running;
                    self.timer.reset();
                }

                return true;
            },
            .Running => {
                if (self.iter < self.count) {
                    self.iter += 1;
                    return true;
                } else {
                    self.nanoseconds = self.timer.read();
                    self.state = .Finished;
                    return false;
                }
            },
            .Finished => unreachable,
        }
    }

    pub fn startTimer(self: *Context) void {
        self.timer.reset();
    }

    pub fn stopTimer(self: *Context) void {
        const elapsed = self.timer.read();
        self.nanoseconds += elapsed;
    }

    pub fn runExplicitTiming(self: *Context) bool {
        switch (self.state) {
            .None => {
                self.state = .Heating;
                return true;
            },
            .Heating => {
                self.count += 1;
                if (self.nanoseconds >= HeatingTime) {
                    // Caches should be hot
                    self.count = @intCast(u32, RunTime / (HeatingTime / self.count));
                    self.nanoseconds = 0;
                    self.state = .Running;
                }

                return true;
            },
            .Running => {
                if (self.iter < self.count) {
                    self.iter += 1;
                    return true;
                } else {
                    self.state = .Finished;
                    return false;
                }
            },
            .Finished => unreachable,
        }
    }

    pub fn averageTime(self: *Context, unit: u64) f32 {
        assert(self.state == .Finished);
        return @intToFloat(f32, self.nanoseconds / unit) / @intToFloat(f32, self.iter);
    }
};

pub fn benchmark(name: comptime []const u8, comptime f: BenchFn) void {
    var ctx = Context.init();

    var result: void = undefined;
    var frame: @Frame(f) = undefined;
    _ = @asyncCall(&frame, &result, f, .{&ctx});
    await frame;

    var unit: u64 = undefined;
    var unit_name: []const u8 = undefined;
    const avg_time = ctx.averageTime(1);
    assert(avg_time >= 0);

    if (avg_time <= time.ns_per_us) {
        unit = 1;
        unit_name = "ns";
    } else if (avg_time <= time.ns_per_ms) {
        unit = time.ns_per_us;
        unit_name = "us";
    } else {
        unit = time.ns_per_ms;
        unit_name = "ms";
    }

    warn("{s}: avg {d:.3}{s} ({} iterations)\n", .{ name, ctx.averageTime(unit), unit_name, ctx.iter });
}

fn benchArgFn(comptime argType: type) type {
    return fn (*Context, argType) void;
}

fn argTypeFromFn(comptime f: anytype) type {
    comptime const F = @TypeOf(f);
    if (@typeInfo(F) != .Fn) {
        @compileError("Argument must be a function.");
    }

    const fnInfo = @typeInfo(F).Fn;
    if (fnInfo.args.len != 2) {
        @compileError("Only functions taking 1 argument are accepted.");
    }

    return fnInfo.args[1].arg_type.?;
}

pub fn benchmarkArgs(comptime name: []const u8, comptime f: anytype, comptime args: []const argTypeFromFn(f)) void {
    inline for (args) |a| {
        var ctx = Context.init();

        comptime const arg_type = argTypeFromFn(f);
        comptime const bench_fn_type: type = fn (*Context, arg_type) callconv(.Async) void;
        comptime const f2: bench_fn_type = f;

        var result: void = undefined;
        var frame: @Frame(f2) = undefined;
        _ = @asyncCall(&frame, &result, f2, .{&ctx, a});
        await frame;

        var unit: u64 = undefined;
        var unit_name: []const u8 = undefined;
        const avg_time = ctx.averageTime(1);
        assert(avg_time >= 0);

        if (avg_time <= time.ns_per_us) {
            unit = 1;
            unit_name = "ns";
        } else if (avg_time <= time.ns_per_ms) {
            unit = time.ns_per_us;
            unit_name = "us";
        } else {
            unit = time.ns_per_ms;
            unit_name = "ms";
        }

        warn("{s} <{s}>: avg {d:.3}{s} ({} iterations)\n", .{ name, if (@TypeOf(a) == type) @typeName(a) else "", ctx.averageTime(unit), unit_name, ctx.iter });
    }
}

pub fn doNotOptimize(value: anytype) void {
    // LLVM triggers an assert if we pass non-trivial types as inputs for the
    // asm volatile expression.
    // Workaround until asm support is better on Zig's end.
    const T = @TypeOf(value);
    const typeId = @typeId(T);
    switch (typeId) {
        .Bool, .Int, .Float => {
            asm volatile (""
                :
                : [_] "r,m" (value)
                : "memory"
            );
        },
        .Optional => {
            if (value) |v| doNotOptimize(v);
        },
        .Struct => {
            inline for (comptime std.meta.fields(T)) |field| {
                doNotOptimize(@field(value, field.name));
            }
        },
        .Type, .Void, .NoReturn, .ComptimeFloat, .ComptimeInt, .Undefined, .Null, .Fn, .BoundFn => @compileError("doNotOptimize makes no sense for " ++ @tagName(typeId)),
        else => @compileError("doNotOptimize is not implemented for " ++ @tagName(typeId)),
    }
}

pub fn clobberMemory() void {
    asm volatile (""
        :
        :
        : "memory"
    );
}

test "benchmark" {
    const benchSleep57 = struct {
        fn benchSleep57(ctx: *Context) void {
            while (ctx.run()) {
                time.sleep(57 * time.ns_per_ms);
            }
        }
    }.benchSleep57;

    std.debug.warn("\n", .{});
    benchmark("Sleep57", benchSleep57);
}

test "benchmarkArgs" {
    const benchSleep = struct {
        fn benchSleep(ctx: *Context, ms: u32) void {
            while (ctx.run()) {
                time.sleep(ms * time.ns_per_ms);
            }
        }
    }.benchSleep;

    std.debug.warn("\n", .{});
    benchmarkArgs("Sleep", benchSleep, &[_]u32{ 20, 30, 57 });
}

test "benchmark custom timing" {
    const sleep = struct {
        fn sleep(ctx: *Context) void {
            while (ctx.runExplicitTiming()) {
                time.sleep(30 * time.ns_per_ms);
                ctx.startTimer();
                defer ctx.stopTimer();
                time.sleep(10 * time.ns_per_ms);
            }
        }
    }.sleep;

    std.debug.warn("\n", .{});
    benchmark("sleep", sleep);
}
