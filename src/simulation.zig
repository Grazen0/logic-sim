const std = @import("std");
const core = @import("./core.zig");
const structs = @import("./structs/structs.zig");
const consts = @import("./consts.zig");
const globals = @import("./globals.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const DefaultPrng = std.Random.DefaultPrng;
const BinaryHeap = structs.BinaryHeap;
const Order = std.math.Order;
const SlotMap = structs.SlotMap;
const SecondaryMap = structs.SecondaryMap;
const Deque = structs.Deque;
const Module = core.Module;
const CustomModule = core.CustomModule;
const WireSrc = CustomModule.WireSrc;
const WireDest = CustomModule.WireDest;
const PortKey = CustomModule.PortKey;

const assert = std.debug.assert;

const child_gen_init = 0;

fn greaterByField(comptime T: type, comptime field_name: []const u8) fn (T, T) bool {
    comptime {
        if (!@hasField(T, field_name))
            @compileError(@typeName(T) ++ " must have a `" ++ field_name ++ "` field");
    }

    return struct {
        fn f(lhs: T, rhs: T) bool {
            return @field(lhs, field_name) > @field(rhs, field_name);
        }
    }.f;
}

var prng: *DefaultPrng = undefined;
var rand: std.Random = undefined;

pub fn initPrng(val: *DefaultPrng) void {
    prng = val;
    rand = prng.random();
}

pub const AffectedOutput = struct {
    time: u64,
    output: CustomModule.OutputRef,
    values: []bool,

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        gpa.free(self.values);
        self.* = undefined;
    }
};

pub const ModuleInstance = union(enum) {
    const Self = @This();

    const LogicGate = struct {
        const Event = struct {
            in: struct {
                input: ?usize,
                values: []bool,
            },
            time: u64,

            pub fn deinit(self: *@This(), gpa: Allocator) void {
                gpa.free(self.in.values);
            }
        };

        in_queue: BinaryHeap(Event, greaterByField(Event, "time")),
        kind: Module.LogicGate.Kind,
        inputs: []bool,
        output: bool,
        next_out: ?u64,

        fn generateDelay() u64 {
            return 25 + rand.uintLessThan(u64, 10);
        }

        pub fn init(gpa: Allocator, gate: Module.LogicGate, time: u64) !@This() {
            const inputs = try gpa.alloc(bool, gate.input_cnt);
            @memset(inputs, false);

            return .{
                .in_queue = .empty,
                .kind = gate.kind,
                .inputs = inputs,
                .output = false,
                .next_out = time + generateDelay(),
            };
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            for (self.in_queue.data.items) |*ev| ev.deinit(gpa);
            self.in_queue.deinit(gpa);

            gpa.free(self.inputs);
            self.* = undefined;
        }

        pub fn computeOutput(self: @This()) bool {
            var out = self.inputs[0];

            for (self.inputs[1..]) |b| {
                out = switch (self.kind) {
                    .@"and", .nand => out and b,
                    .@"or", .nor => out or b,
                    .xor => out ^ b,
                };
            }

            if (self.kind == .nand or self.kind == .nor)
                out = !out;

            return out;
        }

        pub fn nextEventTime(self: @This()) ?u64 {
            const event_time = if (self.in_queue.peek()) |ev| ev.time else null;
            const out_time = if (self.next_out) |t| t else null;
            return if (lessThanOptional(u64, event_time, out_time)) event_time else out_time;
        }

        pub fn writeInput(self: *@This(), gpa: Allocator, input: ?usize, values: []const bool, time: u64) !void {
            try self.in_queue.add(gpa, .{
                .in = .{
                    .input = input,
                    .values = try gpa.dupe(bool, values),
                },
                .time = time,
            });
        }

        pub fn processEvent(self: *@This(), gpa: Allocator) ![]AffectedOutput {
            const event_time = if (self.in_queue.peek()) |ev| ev.time else null;
            const out_time = if (self.next_out) |t| t else null;

            if (lessThanOptional(u64, event_time, out_time)) {
                self.processInputEvent(gpa);
                return &.{};
            }

            return try self.processOutputEvent(gpa);
        }

        fn processInputEvent(self: *@This(), gpa: Allocator) void {
            var event = self.in_queue.remove();
            defer event.deinit(gpa);

            if (event.in.input) |idx| {
                assert(event.in.values.len == 1);
                if (self.inputs[idx] == event.in.values[0])
                    return;

                self.inputs[idx] = event.in.values[0];
            } else {
                if (self.inputs.len != event.in.values.len or std.mem.eql(bool, self.inputs, event.in.values))
                    return;

                @memcpy(self.inputs, event.in.values);
            }

            self.next_out = event.time + generateDelay();
        }

        fn processOutputEvent(self: *@This(), gpa: Allocator) ![]AffectedOutput {
            const time = self.next_out.?;
            self.next_out = null;

            const new_output = self.computeOutput();
            if (self.output == new_output)
                return &.{};

            self.output = new_output;

            return try gpa.dupe(AffectedOutput, &.{.{
                .output = .logic_gate,
                .values = try gpa.dupe(bool, @ptrCast(&self.output)),
                .time = time,
            }});
        }
    };

    const NotGate = struct {
        const Event = struct {
            in: bool,
            time: u64,
        };

        in_queue: BinaryHeap(Event, greaterByField(Event, "time")),
        in: bool,
        out: bool,
        next_out: ?u64,

        fn generateDelay() u64 {
            return 15 + rand.uintLessThan(u64, 10);
        }

        pub fn init(time: u64) @This() {
            return .{
                .in_queue = .empty,
                .in = false,
                .out = false,
                .next_out = time + generateDelay(),
            };
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            self.in_queue.deinit(gpa);
            self.* = undefined;
        }

        pub fn writeInput(self: *@This(), gpa: Allocator, values: []const bool, time: u64) !void {
            assert(values.len == 1);
            try self.in_queue.add(gpa, .{ .in = values[0], .time = time });
        }

        pub fn nextEventTime(self: @This()) ?u64 {
            const event_time = if (self.in_queue.peek()) |ev| ev.time else null;
            const out_time = if (self.next_out) |t| t else null;
            return if (lessThanOptional(u64, event_time, out_time)) event_time else out_time;
        }

        pub fn processEvent(self: *@This(), gpa: Allocator) ![]AffectedOutput {
            const event_time = if (self.in_queue.peek()) |ev| ev.time else null;
            const out_time = if (self.next_out) |t| t else null;

            if (lessThanOptional(u64, event_time, out_time)) {
                self.processInputEvent();
                return &.{};
            }

            return try self.processOutputEvent(gpa);
        }

        fn processInputEvent(self: *@This()) void {
            const event = self.in_queue.remove();
            if (self.in == event.in)
                return;

            self.in = event.in;

            self.next_out = event.time + generateDelay();
        }

        fn processOutputEvent(self: *@This(), gpa: Allocator) ![]AffectedOutput {
            const time = self.next_out.?;
            self.next_out = null;

            const new_out = !self.in;
            if (self.out == new_out)
                return &.{};

            self.out = new_out;

            return try gpa.dupe(AffectedOutput, &.{.{
                .output = .not_gate,
                .values = try gpa.dupe(bool, @ptrCast(&self.out)),
                .time = time,
            }});
        }
    };

    const Split = struct {
        const Event = struct {
            in: []bool,
            time: u64,

            pub fn deinit(self: *@This(), gpa: Allocator) void {
                gpa.free(self.in);
            }
        };

        in_queue: BinaryHeap(Event, greaterByField(Event, "time")),
        in: []bool,
        out: []bool,
        output_from: usize,

        pub fn init(gpa: Allocator, split: Module.Split) !@This() {
            const in = try gpa.alloc(bool, split.input_width);
            const out = try gpa.alloc(bool, split.outputWidth());

            @memset(in, false);
            @memset(out, false);

            return .{
                .in_queue = .empty,
                .in = in,
                .out = out,
                .output_from = split.output_from,
            };
        }

        pub fn nextEventTime(self: @This()) ?u64 {
            const next_event = self.in_queue.peek() orelse return null;
            return next_event.time;
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            for (self.in_queue.data.items) |*ev| ev.deinit(gpa);
            self.in_queue.deinit(gpa);

            gpa.free(self.in);
            gpa.free(self.out);
            self.* = undefined;
        }

        pub fn outputTo(self: @This()) usize {
            return self.output_from + self.out.len - 1;
        }

        pub fn writeInput(self: *@This(), gpa: Allocator, values: []const bool, time: u64) !void {
            try self.in_queue.add(gpa, .{
                .in = try gpa.dupe(bool, values),
                .time = time,
            });
        }

        pub fn processEvent(self: *@This(), gpa: Allocator) ![]AffectedOutput {
            var event = self.in_queue.remove();
            defer event.deinit(gpa);

            if (self.in.len != event.in.len or std.mem.eql(bool, self.in, event.in))
                return &.{};

            @memcpy(self.in, event.in);
            @memcpy(self.out, self.in[self.output_from..(self.outputTo() + 1)]);

            return try gpa.dupe(AffectedOutput, &.{.{
                .output = .split,
                .values = try gpa.dupe(bool, self.out),
                .time = event.time,
            }});
        }
    };

    const Join = struct {
        const Event = struct {
            input_idx: usize,
            values: []bool,
            time: u64,

            pub fn deinit(self: *@This(), gpa: Allocator) void {
                gpa.free(self.values);
            }
        };

        in_queue: BinaryHeap(Event, greaterByField(Event, "time")),
        inputs: [][]bool,
        output: []bool,

        pub fn init(gpa: Allocator, join: Module.Join) !@This() {
            const inputs = try gpa.alloc([]bool, join.inputs.len);

            for (0..inputs.len) |i| {
                inputs[i] = try gpa.alloc(bool, join.inputs[i]);
                @memset(inputs[i], false);
            }

            const output = try gpa.alloc(bool, join.outputWidth());
            @memset(output, false);

            return .{
                .in_queue = .empty,
                .inputs = inputs,
                .output = output,
            };
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            for (self.in_queue.data.items) |*ev| ev.deinit(gpa);
            self.in_queue.deinit(gpa);

            for (self.inputs) |input|
                gpa.free(input);

            gpa.free(self.inputs);
            gpa.free(self.output);
            self.* = undefined;
        }

        pub fn nextEventTime(self: @This()) ?u64 {
            const next_event = self.in_queue.peek() orelse return null;
            return next_event.time;
        }

        pub fn writeInput(self: *@This(), gpa: Allocator, input_idx: usize, values: []const bool, time: u64) !void {
            try self.in_queue.add(gpa, .{
                .input_idx = input_idx,
                .values = try gpa.dupe(bool, values),
                .time = time,
            });
        }

        pub fn processEvent(self: *@This(), gpa: Allocator) ![]AffectedOutput {
            var event = self.in_queue.remove();
            defer event.deinit(gpa);

            const input = self.inputs[event.input_idx];

            if (input.len != event.values.len or std.mem.eql(bool, input, event.values))
                return &.{};

            var start: usize = 0;
            for (0..event.input_idx) |i|
                start += self.inputs[i].len;

            @memcpy(input, event.values);
            @memcpy(self.output[start .. start + input.len], input);

            return try gpa.dupe(AffectedOutput, &.{.{
                .output = .join,
                .values = try gpa.dupe(bool, self.output),
                .time = event.time,
            }});
        }
    };

    pub const Display = struct {
        const Event = struct {
            values: []bool,
            time: u64,

            pub fn deinit(self: *@This(), gpa: Allocator) void {
                gpa.free(self.values);
            }
        };

        in_queue: BinaryHeap(Event, greaterByField(Event, "time")),
        values: []bool,
        mode: Module.Display.Mode,

        pub fn init(gpa: Allocator, display: Module.Display) !@This() {
            const values = try gpa.alloc(bool, display.input_width);
            @memset(values, false);

            return .{
                .in_queue = .empty,
                .values = values,
                .mode = display.mode,
            };
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            for (self.in_queue.data.items) |*ev|
                ev.deinit(gpa);

            self.in_queue.deinit(gpa);
            gpa.free(self.values);

            self.* = undefined;
        }

        pub fn nextEventTime(self: @This()) ?u64 {
            const next_event = self.in_queue.peek() orelse return null;
            return next_event.time;
        }

        pub fn writeInput(self: *@This(), gpa: Allocator, values: []const bool, time: u64) !void {
            try self.in_queue.add(gpa, .{
                .values = try gpa.dupe(bool, values),
                .time = time,
            });
        }

        pub fn processEvent(self: *@This(), gpa: Allocator) ![]AffectedOutput {
            var event = self.in_queue.remove();
            defer event.deinit(gpa);

            @memcpy(self.values, event.values);
            return &.{};
        }
    };

    const Clock = struct {
        freq: f32,
        next_time: u64,
        out: bool,

        pub fn init(clock: Module.Clock, time: u64) @This() {
            return .{
                .freq = clock.freq,
                .next_time = time,
                .out = false,
            };
        }

        fn period(self: @This()) f32 {
            return 1 / self.freq;
        }

        fn periodLogicTime(self: @This()) u64 {
            return @intFromFloat(consts.logic_time_per_sec * (self.period() / 2));
        }

        pub fn nextEventTime(self: @This()) ?u64 {
            return self.next_time;
        }

        pub fn processEvent(self: *@This(), gpa: Allocator) ![]AffectedOutput {
            self.out = !self.out;

            const affected = try gpa.dupe(AffectedOutput, &.{.{
                .output = .clock,
                .time = self.next_time,
                .values = try gpa.dupe(bool, @ptrCast(&self.out)),
            }});

            self.next_time += self.periodLogicTime();

            return affected;
        }
    };

    logic_gate: LogicGate,
    not_gate: NotGate,
    split: Split,
    join: Join,
    display: Display,
    clock: Clock,
    custom: CustomModuleInstance,

    pub fn init(gpa: Allocator, module: Module, time: u64) error{OutOfMemory}!Self {
        return switch (module) {
            .logic_gate => |gate| .{ .logic_gate = try .init(gpa, gate, time) },
            .not_gate => .{ .not_gate = .init(time) },
            .split => |split| .{ .split = try .init(gpa, split) },
            .join => |join| .{ .join = try .init(gpa, join) },
            .display => |display| .{ .display = try .init(gpa, display) },
            .clock => |clock| .{ .clock = .init(clock, time) },
            .custom => |mod_key| .{ .custom = try .init(gpa, mod_key, time) },
        };
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        switch (self.*) {
            .logic_gate => |*gate| gate.deinit(gpa),
            .not_gate => |*gate| gate.deinit(gpa),
            .split => |*split| split.deinit(gpa),
            .join => |*join| join.deinit(gpa),
            .display => |*display| display.deinit(gpa),
            .clock => {},
            .custom => |*custom| custom.deinit(gpa),
        }
    }

    pub fn readOutput(self: *const Self, output: CustomModule.OutputRef) []const bool {
        return switch (self.*) {
            .logic_gate => |*gate| @ptrCast(&gate.output),
            .not_gate => |*gate| @ptrCast(&gate.out),
            .split => |*split| split.out,
            .join => |*join| join.output,
            .display => unreachable,
            .clock => |*clock| @ptrCast(&clock.out),
            .custom => |*custom| custom.outputs.get(output.custom).?,
        };
    }

    pub fn nextEventTime(self: *Self) ?u64 {
        return switch (self.*) {
            .logic_gate => |*gate| gate.nextEventTime(),
            .not_gate => |*gate| gate.nextEventTime(),
            .split => |*split| split.nextEventTime(),
            .join => |*join| join.nextEventTime(),
            .display => |*display| display.nextEventTime(),
            .clock => |*clock| clock.nextEventTime(),
            .custom => |*custom| custom.nextEventTime(),
        };
    }

    pub fn processEvent(self: *Self, gpa: Allocator) ![]AffectedOutput {
        return switch (self.*) {
            .logic_gate => |*gate| try gate.processEvent(gpa),
            .not_gate => |*gate| try gate.processEvent(gpa),
            .split => |*split| try split.processEvent(gpa),
            .join => |*join| try join.processEvent(gpa),
            .display => |*display| try display.processEvent(gpa),
            .clock => |*clock| try clock.processEvent(gpa),
            .custom => |*custom| try custom.processEvent(gpa),
        };
    }

    pub fn writeInput(self: *Self, gpa: Allocator, ref: CustomModule.InputRef, values: []const bool, time: u64) !void {
        switch (self.*) {
            .logic_gate => |*gate| try gate.writeInput(gpa, ref.logic_gate, values, time),
            .not_gate => |*gate| try gate.writeInput(gpa, values, time),
            .split => |*split| try split.writeInput(gpa, values, time),
            .join => |*join| try join.writeInput(gpa, ref.join, values, time),
            .display => |*display| try display.writeInput(gpa, values, time),
            .clock => unreachable,
            .custom => |*custom| try custom.writeInput(gpa, ref.custom, values, time),
        }
    }
};

fn lessThanOptional(comptime T: type, lhs: ?T, rhs: ?T) bool {
    if (lhs == null)
        return false;

    return rhs == null or lhs.? < rhs.?;
}

pub const CustomModuleInstance = struct {
    const Self = @This();

    const Event = struct {
        const Top = struct {
            src: WireSrc,
            values: []bool,
        };

        const Child = struct {
            child_key: CustomModule.Child.Key,
            gen: u64,
        };

        time: u64,
        v: union(enum) {
            top: Top,
            child: Child,
        },

        pub fn top(src: WireSrc, values: []bool, time: u64) @This() {
            return .{
                .time = time,
                .v = .{
                    .top = .{
                        .src = src,
                        .values = values,
                    },
                },
            };
        }

        pub fn child(child_key: CustomModule.Child.Key, gen: u64, time: u64) @This() {
            return .{
                .time = time,
                .v = .{
                    .child = .{ .child_key = child_key, .gen = gen },
                },
            };
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            if (self.v == .top)
                gpa.free(self.v.top.values);

            self.* = undefined;
        }
    };

    mod_key: CustomModule.Key,
    inputs: SecondaryMap(PortKey, []bool),
    outputs: SecondaryMap(PortKey, []bool),
    children: SecondaryMap(CustomModule.Child.Key, ModuleInstance),
    child_gens: SecondaryMap(CustomModule.Child.Key, u64),
    queue: BinaryHeap(Event, greaterByField(Event, "time")),

    pub fn init(gpa: Allocator, mod_key: CustomModule.Key, time: u64) !Self {
        const mod = globals.modules.get(mod_key).?;

        var inputs: SecondaryMap(PortKey, []bool) = .empty;
        var input_iter = mod.inputs.constIterator();

        while (input_iter.next()) |entry| {
            const values = try gpa.alloc(bool, entry.val.width);
            @memset(values, false);
            _ = try inputs.put(gpa, entry.key, values);
        }

        var outputs: SecondaryMap(PortKey, []bool) = .empty;
        var output_iter = mod.outputs.constIterator();

        while (output_iter.next()) |entry| {
            const values = try gpa.alloc(bool, entry.val.width);
            @memset(values, false);
            _ = try outputs.put(gpa, entry.key, values);
        }

        var out: Self = .{
            .mod_key = mod_key,
            .inputs = inputs,
            .outputs = outputs,
            .children = .empty,
            .child_gens = .empty,
            .queue = .empty,
        };

        var children_iter = mod.children.constIterator();
        while (children_iter.nextKey()) |child_key|
            try out.addChild(gpa, child_key, time);

        return out;
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        var inputs_iter = self.inputs.iterator();
        while (inputs_iter.nextValue()) |values|
            gpa.free(values.*);

        var outputs_iter = self.outputs.iterator();
        while (outputs_iter.nextValue()) |values|
            gpa.free(values.*);

        var children_iter = self.children.iterator();
        while (children_iter.nextValue()) |child|
            child.deinit(gpa);

        for (self.queue.data.items) |*entry|
            entry.deinit(gpa);

        self.inputs.deinit(gpa);
        self.outputs.deinit(gpa);
        self.children.deinit(gpa);
        self.child_gens.deinit(gpa);
        self.queue.deinit(gpa);

        self.* = undefined;
    }

    pub fn nextEventTime(self: *Self) ?u64 {
        self.pruneQueue();
        const next_event = self.queue.peek() orelse return null;
        return next_event.time;
    }

    fn pruneQueue(self: *Self) void {
        while (self.queue.peek()) |entry| {
            const child_event = if (entry.v == .child) entry.v.child else break;
            const child_gen = self.child_gens.get(child_event.child_key);

            if (child_gen != null and child_event.gen == child_gen.?)
                break;

            _ = self.queue.remove();
        }
    }

    pub fn processEvent(self: *Self, gpa: Allocator) ![]AffectedOutput {
        self.pruneQueue();
        var event = self.queue.remove();
        defer event.deinit(gpa);

        switch (event.v) {
            .top => |top_event| return try self.processTopEvent(gpa, top_event, event.time),
            .child => |child_event| {
                try self.processChildEvent(gpa, child_event);
                return &.{};
            },
        }
    }

    fn processTopEvent(self: *Self, gpa: Allocator, event: Event.Top, time: u64) ![]AffectedOutput {
        const mod = globals.modules.get(self.mod_key).?;

        if (event.src == .top_input) {
            const input = self.inputs.get(event.src.top_input).?;
            if (std.mem.eql(bool, input, event.values))
                return &.{};

            @memcpy(input, event.values);
        }

        var affected: ArrayList(AffectedOutput) = .empty;
        var wire_iter = mod.wires.constIterator();

        while (wire_iter.nextValue()) |wire| {
            if (wire.from.equals(event.src)) {
                const wire_affected = try self.writeWireDest(gpa, wire.to, event.values, time);

                if (wire_affected) |af|
                    try affected.append(gpa, af);
            }
        }

        return try affected.toOwnedSlice(gpa);
    }

    fn processChildEvent(self: *Self, gpa: Allocator, event: Event.Child) error{OutOfMemory}!void {
        const child = self.children.getPtr(event.child_key) orelse return;

        const child_affected = try child.processEvent(gpa);
        defer gpa.free(child_affected);
        defer for (child_affected) |*af| af.deinit(gpa);

        for (child_affected) |af| {
            const src: WireSrc = .{
                .child_output = .{
                    .child_key = event.child_key,
                    .output = af.output,
                },
            };
            try self.queue.add(gpa, .top(src, try gpa.dupe(bool, af.values), af.time));
        }

        if (child.nextEventTime()) |t| {
            const gen = self.child_gens.get(event.child_key).?;
            try self.queue.add(gpa, .child(event.child_key, gen, t));
        }
    }

    pub fn writeInput(self: *Self, gpa: Allocator, input_key: PortKey, values: []const bool, time: u64) !void {
        try self.queue.add(gpa, .top(.{ .top_input = input_key }, try gpa.dupe(bool, values), time));
    }

    pub fn readWireSrc(self: *const Self, src: WireSrc) []const bool {
        return switch (src) {
            .top_input => |input_key| self.inputs.get(input_key).?,
            .child_output => |ref| blk: {
                const child = self.children.getPtr(ref.child_key).?;
                break :blk child.readOutput(ref.output);
            },
        };
    }

    pub fn writeWireDest(self: *Self, gpa: Allocator, dest: WireDest, values: []const bool, time: u64) !?AffectedOutput {
        switch (dest) {
            .top_output => |output_key| {
                const output = self.outputs.get(output_key).?;
                if (std.mem.eql(bool, output, values))
                    return null;

                @memcpy(output, values);

                return .{
                    .output = .{ .custom = output_key },
                    .time = time,
                    .values = try gpa.dupe(bool, output),
                };
            },
            .child_input => |ref| {
                const child_inst = self.children.getPtr(ref.child_key).?;
                try child_inst.writeInput(gpa, ref.input, values, time);

                const gen = self.child_gens.getPtr(ref.child_key).?;
                gen.* += 1;

                if (child_inst.nextEventTime()) |t|
                    try self.queue.add(gpa, .child(ref.child_key, gen.*, t));

                return null;
            },
        }
    }

    pub fn addChild(self: *Self, gpa: Allocator, child_key: CustomModule.Child.Key, time: u64) !void {
        const mod = globals.modules.getPtr(self.mod_key).?;
        const child = mod.children.get(child_key).?;

        var child_inst: ModuleInstance = try .init(gpa, child.mod, time);
        _ = try self.children.put(gpa, child_key, child_inst);
        _ = try self.child_gens.put(gpa, child_key, child_gen_init);

        if (child_inst.nextEventTime()) |t|
            try self.queue.add(gpa, .child(child_key, child_gen_init, t));
    }

    pub fn removeChildNoAffectWires(self: *Self, gpa: Allocator, child_key: CustomModule.Child.Key) void {
        var removed = self.children.remove(child_key).?;
        defer removed.deinit(gpa);

        _ = self.child_gens.remove(child_key).?;
    }

    pub fn removeChildWithMod(self: *Self, gpa: Allocator, child_key: CustomModule.Child.Key, time: u64) !void {
        const mod = globals.modules.getPtr(self.mod_key).?;

        self.removeChildNoAffectWires(gpa, child_key);
        mod.removeChildNoAffectWires(gpa, child_key);
        try self.pruneInvalidWiresWithMod(gpa, time);
    }

    pub fn addWire(self: *Self, gpa: Allocator, wire_key: CustomModule.WireKey, time: u64) !void {
        const mod = globals.modules.getPtr(self.mod_key).?;
        const wire = mod.wires.get(wire_key).?;
        const values = self.readWireSrc(wire.from);

        var affected = try self.writeWireDest(gpa, wire.to, values, time);
        defer if (affected) |*af| af.deinit(gpa);
    }

    pub fn removeWire(self: *Self, gpa: Allocator, wire: CustomModule.Wire, time: u64) !?AffectedOutput {
        const mod = globals.modules.getPtr(self.mod_key).?;
        const wire_width = mod.wireDestWidth(wire.to);

        const false_values = try gpa.alloc(bool, wire_width);
        defer gpa.free(false_values);
        @memset(false_values, false);

        return try self.writeWireDest(gpa, wire.to, false_values, time);
    }

    // Duplicated from Module but also updates simulation values here.
    pub fn pruneInvalidWiresWithMod(self: *Self, gpa: Allocator, time: u64) !void {
        const mod = globals.modules.getPtr(self.mod_key).?;
        var wire_iter = mod.wires.constIterator();

        while (wire_iter.next()) |entry| {
            const wire = entry.val.*;
            const wire_key = entry.key;

            if (!mod.isWireValid(wire)) {
                var removed = mod.wires.remove(wire_key).?;
                defer removed.deinit(gpa);

                if (mod.isWireDestValid(wire.to)) {
                    const values = try gpa.alloc(bool, mod.wireDestWidth(wire.to));
                    defer gpa.free(values);
                    @memset(values, false);

                    var affected = try self.writeWireDest(gpa, wire.to, values, time);
                    defer if (affected) |*af| af.deinit(gpa);
                }
            }
        }
    }

    pub fn reinstantiateChild(self: *Self, gpa: Allocator, child_key: CustomModule.Child.Key, time: u64) !void {
        const mod = globals.modules.getPtr(self.mod_key).?;
        const child = mod.children.get(child_key).?;

        const new_inst: ModuleInstance = try .init(gpa, child.mod, time);
        var removed = (try self.children.put(gpa, child_key, new_inst)).?;
        defer removed.deinit(gpa);

        var wire_iter = mod.wires.constIterator();
        while (wire_iter.nextValue()) |wire| {
            if (wire.to == .child_input and wire.to.child_input.child_key.equals(child_key)) {
                const src_values = self.readWireSrc(wire.from);
                const affected = try self.writeWireDest(gpa, wire.to, src_values, time);
                assert(affected == null);
            }
        }
    }
};
