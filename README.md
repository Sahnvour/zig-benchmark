# Goal

zig-benchmark provides a minimal API to do micro-benchmarking.

Everything it contains is very barebones compared to mature benchmarking frameworks, but usable nonetheless.

# Features

* easy to use
* runs every micro-benchmark in fixed time
* pre-warming, to get the caches ready
* ugly text report

# Example

## Simple

```zig
const bench = @import("bench.zig");

fn longCompute(ctx: *bench.Context) void {
    while (ctx.run()) {
        // something you want to time
    }
}

pub fn main() void {
    bench.benchmark("longCompute", longCompute);
}
```

## With arguments

```zig
const bench = @import("bench.zig");

fn longCompute(ctx: *bench.Context, x: u32) void {
    while (ctx.run()) {
        // something you want to time
    }
}

pub fn main() void {
    bench.benchmarkArgs("longCompute", longCompute, []const u32{ 1, 2, 3, 4 });
}
```

Works with `type`s as arguments, too.

## With explicit timing

```zig
const bench = @import("bench.zig");

fn longCompute(ctx: *bench.Context) void {
    while (ctx.runExplicitTiming()) {
        // do some set-up

        ctx.startTimer();
        // something you want to time
        ctx.stopTimer();
    }
}

pub fn main() void {
    bench.benchmark("longCompute", longCompute);
}
```