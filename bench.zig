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
    f(&ctx);
    var unit: u64 = undefined;
    var unit_name: []const u8 = undefined;
    switch (ctx.averageTime(1)) {
        0...time.microsecond => {
            unit = 1;
            unit_name = "ns";
        },
        time.microsecond + 1...time.millisecond => {
            unit = time.microsecond;
            unit_name = "µs";
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
    comptime if (@typeId(@typeOf(f)) != TypeId.Fn) {
        @compileError("Third argument must be a function.");
    };

    inline for (args) |a| {
        var ctx = Context.init();
        f(&ctx, a);
        var unit: u64 = undefined;
        var unit_name: []const u8 = undefined;
        switch (ctx.averageTime(1)) {
            0...time.microsecond => {
                unit = 1;
                unit_name = "ns";
            },
            time.microsecond + 1...time.millisecond => {
                unit = time.microsecond;
                unit_name = "µs";
            },
            else => {
                unit = time.millisecond;
                unit_name = "ms";
            }
        }
        warn("{}<{}>: avg {.3}{} ({} iterations)\n", name, if (@typeOf(a) == type) @typeName(a) else a, ctx.averageTime(unit), unit_name, ctx.iter);
    }
}

fn foo(ms: u32) void {
    time.sleep(ms * time.millisecond);
}

fn benchFoo57(ctx: *Context) void {
    while (ctx.run()) {
        foo(57);
    }
}

fn benchFoo(ctx: *Context, ms: u32) void {
    while (ctx.run()) {
        foo(ms);
    }
}

fn min(comptime T: type, a: T, b: T) T {
    return if (a < b) a else b;
}

fn benchMin(ctx: *Context, comptime intType: type) void {
    while (ctx.run()) {
        foo(@intCast(u32, min(intType, 37, 48)));
    }
}

pub fn main() void {
    benchmark("Foo57", benchFoo57);
    benchmarkArgs("Foo", benchFoo, []const u32{20, 30, 57, 241});
    benchmarkArgs("Min", benchMin, []type{u32, u64});
}