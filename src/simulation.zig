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
        next_out: ?struct {
            value: bool,
            time: u64,
        },

        pub fn init(gpa: Allocator, gate: Module.LogicGate) !@This() {
            const inputs = try gpa.alloc(bool, gate.input_cnt);
            @memset(inputs, false);

            var out: @This() = .{
                .in_queue = .empty,
                .kind = gate.kind,
                .inputs = inputs,
                .output = undefined,
                .next_out = null,
            };

            out.output = out.computeOutput();
            return out;
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
            const out_time = if (self.next_out) |o| o.time else null;
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
            const out_time = if (self.next_out) |o| o.time else null;

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
                if (std.mem.eql(bool, self.inputs, event.in.values))
                    return;

                @memcpy(self.inputs, event.in.values);
            }

            const gate_delay = 25 + rand.uintLessThan(u64, 10);
            self.next_out = .{
                .value = self.computeOutput(),
                .time = event.time + gate_delay,
            };
        }

        fn processOutputEvent(self: *@This(), gpa: Allocator) ![]AffectedOutput {
            const out = self.next_out.?;
            self.next_out = null;

            if (self.output == out.value)
                return &.{};

            self.output = out.value;

            return try gpa.dupe(AffectedOutput, &.{.{
                .output = .logic_gate,
                .values = try gpa.dupe(bool, @ptrCast(&self.output)),
                .time = out.time,
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
        next_out: ?struct {
            time: u64,
            value: bool,
        },

        pub const init: @This() = .{
            .in_queue = .empty,
            .in = false,
            .out = true,
            .next_out = null,
        };

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
            const out_time = if (self.next_out) |o| o.time else null;
            return if (lessThanOptional(u64, event_time, out_time)) event_time else out_time;
        }

        pub fn processEvent(self: *@This(), gpa: Allocator) ![]AffectedOutput {
            const event_time = if (self.in_queue.peek()) |ev| ev.time else null;
            const out_time = if (self.next_out) |o| o.time else null;

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

            const gate_delay = 15 + rand.uintLessThan(u64, 10);
            self.next_out = .{
                .value = !self.in,
                .time = event.time + gate_delay,
            };
        }

        fn processOutputEvent(self: *@This(), gpa: Allocator) ![]AffectedOutput {
            const out = self.next_out.?;
            self.next_out = null;

            if (self.out == out.value)
                return &.{};

            self.out = out.value;

            return try gpa.dupe(AffectedOutput, &.{.{
                .output = .not_gate,
                .values = try gpa.dupe(bool, @ptrCast(&self.out)),
                .time = out.time,
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

            if (std.mem.eql(bool, self.in, event.in))
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

    const Clock = struct {
        freq: f32,
        next_time: u64,
        out: bool,

        pub fn init(clock: Module.Clock) @This() {
            return .{
                .freq = clock.freq,
                .next_time = 0,
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
    clock: Clock,
    custom: CustomModuleInstance,

    pub fn init(gpa: Allocator, module: Module) error{OutOfMemory}!Self {
        return switch (module) {
            .logic_gate => |gate| .{ .logic_gate = try .init(gpa, gate) },
            .not_gate => .{ .not_gate = .init },
            .split => |split| .{ .split = try .init(gpa, split) },
            .clock => |clock| .{ .clock = .init(clock) },
            .custom => |mod_key| .{ .custom = try .init(gpa, mod_key) },
        };
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        switch (self.*) {
            .logic_gate => |*gate| gate.deinit(gpa),
            .not_gate => |*gate| gate.deinit(gpa),
            .split => |*split| split.deinit(gpa),
            .clock => {},
            .custom => |*custom| custom.deinit(gpa),
        }
    }

    pub fn readOutput(self: *const Self, output: CustomModule.OutputRef) []const bool {
        return switch (self.*) {
            .logic_gate => |*gate| @ptrCast(&gate.output),
            .not_gate => |*gate| @ptrCast(&gate.out),
            .split => |*split| split.out,
            .clock => |*clock| @ptrCast(&clock.out),
            .custom => |*custom| custom.outputs.get(output.custom).?.*,
        };
    }

    pub fn nextEventTime(self: *Self) ?u64 {
        return switch (self.*) {
            .logic_gate => |*gate| gate.nextEventTime(),
            .not_gate => |*gate| gate.nextEventTime(),
            .split => |*split| split.nextEventTime(),
            .clock => |*clock| clock.nextEventTime(),
            .custom => |*custom| custom.nextEventTime(),
        };
    }

    pub fn processEvent(self: *Self, gpa: Allocator) ![]AffectedOutput {
        return switch (self.*) {
            .logic_gate => |*gate| try gate.processEvent(gpa),
            .not_gate => |*gate| try gate.processEvent(gpa),
            .split => |*split| try split.processEvent(gpa),
            .clock => |*clock| try clock.processEvent(gpa),
            .custom => |*custom| try custom.processEvent(gpa),
        };
    }

    pub fn writeInput(self: *Self, gpa: Allocator, ref: CustomModule.InputRef, values: []const bool, time: u64) !void {
        switch (self.*) {
            .logic_gate => |*gate| try gate.writeInput(gpa, ref.logic_gate, values, time),
            .not_gate => |*gate| try gate.writeInput(gpa, values, time),
            .split => |*split| try split.writeInput(gpa, values, time),
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

    pub fn init(gpa: Allocator, mod_key: CustomModule.Key) !Self {
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

        while (children_iter.next()) |entry| {
            const init_gen = 0;

            const child_key = entry.key;
            const child = entry.val;

            var child_inst: ModuleInstance = try .init(gpa, child.mod);
            _ = try out.children.put(gpa, child_key, child_inst);
            _ = try out.child_gens.put(gpa, child_key, init_gen);

            if (child_inst.nextEventTime()) |nt| {
                try out.queue.add(gpa, .{
                    .time = nt,
                    .v = .{
                        .child = .{
                            .child_key = child_key,
                            .gen = init_gen,
                        },
                    },
                });
            }

            var wire_iter = mod.wires.constIterator();
            while (wire_iter.nextValue()) |wire| {
                if (wire.from == .child_output and wire.from.child_output.child_key.equals(child_key)) {
                    const from_values = out.readWireSrc(wire.from);
                    const power_on_delay = rand.uintLessThan(u64, 10);
                    try out.queue.add(gpa, .top(wire.from, try gpa.dupe(bool, from_values), power_on_delay));
                }
            }
        }

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

    fn selfMod(self: Self) *CustomModule {
        return globals.modules.get(self.mod_key).?;
    }

    pub fn nextEventTime(self: *Self) ?u64 {
        self.pruneQueue();
        const next_event = self.queue.peek() orelse return null;
        return next_event.time;
    }

    fn pruneQueue(self: *Self) void {
        while (self.queue.peek()) |entry| {
            const child_event = if (entry.v == .child) entry.v.child else break;
            if (child_event.gen == self.child_gens.get(child_event.child_key).?.*)
                break;

            _ = self.queue.remove();
        }
    }

    pub fn processEvent(self: *Self, gpa: Allocator) error{OutOfMemory}![]AffectedOutput {
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
        const mod = self.selfMod();
        var affected: ArrayList(AffectedOutput) = .empty;

        if (event.src == .top_input) {
            const input = self.inputs.get(event.src.top_input).?.*;
            if (std.mem.eql(bool, input, event.values))
                return &.{};

            @memcpy(input, event.values);
        }

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

    fn processChildEvent(self: *Self, gpa: Allocator, event: Event.Child) !void {
        self.pruneQueue();

        const child = self.children.get(event.child_key).?;

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

        if (child.nextEventTime()) |nt| {
            const gen = self.child_gens.get(event.child_key).?.*;
            try self.queue.add(gpa, .child(event.child_key, gen, nt));
        }
    }

    pub fn writeInput(self: *Self, gpa: Allocator, input_key: PortKey, values: []const bool, time: u64) !void {
        try self.queue.add(gpa, .top(.{ .top_input = input_key }, try gpa.dupe(bool, values), time));
    }

    pub fn readWireSrc(self: *const Self, src: WireSrc) []const bool {
        return switch (src) {
            .top_input => |input_key| self.inputs.get(input_key).?.*,
            .child_output => |ref| blk: {
                const child = self.children.get(ref.child_key).?;
                break :blk child.readOutput(ref.output);
            },
        };
    }

    pub fn enqueueTopEvent(self: *Self, gpa: Allocator, src: WireSrc, values: []const bool, time: u64) !void {
        try self.queue.add(gpa, .{
            .src = src,
            .values = try gpa.dupe(bool, values),
            .time = time,
        });
    }

    pub fn writeWireDest(self: *Self, gpa: Allocator, dest: WireDest, values: []const bool, time: u64) !?AffectedOutput {
        switch (dest) {
            .top_output => |output_key| {
                const output = self.outputs.get(output_key).?.*;
                @memcpy(output, values);

                return .{
                    .output = .{ .custom = output_key },
                    .time = time,
                    .values = try gpa.dupe(bool, output),
                };
            },
            .child_input => |ref| {
                const child_inst = self.children.get(ref.child_key).?;
                try child_inst.writeInput(gpa, ref.input, values, time);

                const cur_gen = self.child_gens.get(ref.child_key).?;
                cur_gen.* += 1;

                if (child_inst.nextEventTime()) |nt|
                    try self.queue.add(gpa, .child(ref.child_key, cur_gen.*, nt));

                return null;
            },
        }
    }

    pub fn pruneInvalidWires(self: *Self, gpa: Allocator) void {
        const mod = self.selfMod();
        var iter = mod.wires.constIterator();

        while (iter.next()) |entry| {
            if (!mod.isWireValid(entry.val.*)) {
                var removed = mod.wires.remove(entry.key).?;
                defer removed.deinit(gpa);
            }
        }
    }
};
