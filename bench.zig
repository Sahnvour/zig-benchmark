// Copyright 2021 Antoine Vugliano

const std = @import("std");
const assert = std.debug.assert;
const time = std.time;
const print = std.debug.print;

const Timer = time.Timer;

const BenchFn = fn (*Context) void;

pub const Context = struct {
    timer: Timer,
    iter: u32,
    count: u32,
    state: State,
    nanoseconds: u64,

    const HeatingTime = time.ns_per_s / 2;
    const RunTime = time.ns_per_s * 2;

    const State = enum {
        None,
        Heating,
        Running,
        Finished,
    };

    pub fn init() Context {
        return Context{
            .timer = Timer.start() catch unreachable,
            .iter = 0,
            .count = 0,
            .state = .None,
            .nanoseconds = 0,
        };
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
                    self.count = @intCast(RunTime / (HeatingTime / self.count));
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
                    self.count = @intCast(RunTime / (HeatingTime / self.count));
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
        return @as(f32, @floatFromInt(self.nanoseconds / unit)) / @as(f32, @floatFromInt(self.iter));
    }
};

pub fn benchmark(name: []const u8, comptime f: BenchFn) void {
    var ctx = Context.init();
    @call(.never_inline, f, .{&ctx});

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

    print("{s}: avg {d:.3}{s} ({d} iterations)\n", .{ name, ctx.averageTime(unit), unit_name, ctx.iter });
}

fn benchArgFn(comptime argType: type) type {
    return fn (*Context, argType) void;
}

fn argTypeFromFn(comptime f: anytype) type {
    const F = @TypeOf(f);
    if (@typeInfo(F) != .Fn) {
        @compileError("Argument must be a function.");
    }

    const fnInfo = @typeInfo(F).Fn;
    if (fnInfo.params.len != 2) {
        @compileError("Only functions taking 1 argument are accepted.");
    }

    return fnInfo.params[1].type.?;
}

pub fn benchmarkArgs(comptime name: []const u8, comptime f: anytype, comptime args: []const argTypeFromFn(f)) void {
    inline for (args) |arg| {
        var ctx = Context.init();
        @call(.never_inline, f, .{ &ctx, arg });

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

        const typeOfArg = @TypeOf(arg);
        if (typeOfArg == type) {
            print("{s} <{s}>: avg {d:.3}{s} ({d} iterations)\n", .{
                name,
                @typeName(arg),
                ctx.averageTime(unit),
                unit_name,
                ctx.iter,
            });
        } else {
            print("{s} <{any}>: avg {d:.3}{s} ({d} iterations)\n", .{
                name,
                arg,
                ctx.averageTime(unit),
                unit_name,
                ctx.iter,
            });
        }
    }
}

pub fn doNotOptimize(value: anytype) void {
    // LLVM triggers an assert if we pass non-trivial types as inputs for the
    // asm volatile expression.
    // Workaround until asm support is better on Zig's end.
    const T = @TypeOf(value);
    switch (T) {
        .Bool, .Int, .Float => {
            asm volatile (""
                :
                : [_] "r,m" (value),
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
        .Type,
        .Void,
        .NoReturn,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .Fn,
        .BoundFn,
        => @compileError("doNotOptimize makes no sense for " ++ @tagName(T)),
        else => @compileError("doNotOptimize is not implemented for " ++ @tagName(T)),
    }
}

pub fn clobberMemory() void {
    asm volatile ("" ::: "memory");
}

const ENABLE_TESTS = true;

test "benchmark" {
    if (!ENABLE_TESTS) return error.SkipZigTest;

    const benchSleep57 = struct {
        fn benchSleep57(ctx: *Context) void {
            while (ctx.run()) {
                time.sleep(57 * time.ns_per_ms);
            }
        }
    }.benchSleep57;

    benchmark("Sleep57", benchSleep57);
}

test "benchmarkArgs" {
    if (!ENABLE_TESTS) return error.SkipZigTest;

    const benchSleep = struct {
        fn benchSleep(ctx: *Context, ms: u32) void {
            while (ctx.run()) {
                time.sleep(ms * time.ns_per_ms);
            }
        }
    }.benchSleep;

    benchmarkArgs("Sleep", benchSleep, &[_]u32{ 20, 30, 57 });
}

test "benchmarkArgs types" {
    if (!ENABLE_TESTS) return error.SkipZigTest;

    const benchMin = struct {
        fn benchMin(ctx: *Context, comptime intType: type) void {
            while (ctx.run()) {
                const a = @as(intType, 37);
                const b = @as(intType, 48);
                time.sleep(@min(a, b) * @as(intType, time.ns_per_ms));
            }
        }
    }.benchMin;

    benchmarkArgs("Min", benchMin, &[_]type{ u32, u64 });
}

test "benchmark custom timing" {
    if (!ENABLE_TESTS) return error.SkipZigTest;

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

    benchmark("sleep", sleep);
}
