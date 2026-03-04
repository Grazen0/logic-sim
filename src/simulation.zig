const std = @import("std");
const core = @import("./core.zig");
const structs = @import("./structs/structs.zig");
const globals = @import("./globals.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const PriorityQueue = std.PriorityQueue;
const Order = std.math.Order;
const SlotMap = structs.SlotMap;
const SecondaryMap = structs.SecondaryMap;
const Deque = structs.Deque;
const Module = core.Module;
const CustomModule = core.CustomModule;
const WireSrc = CustomModule.WireSrc;
const WireDest = CustomModule.WireDest;

const assert = std.debug.assert;

pub const ModuleInstance = union(enum) {
    const Self = @This();

    logic_gate: struct {
        kind: Module.LogicGate.Kind,
        inputs: ArrayList(bool),
        output: bool,

        pub fn init(gpa: Allocator, kind: Module.LogicGate.Kind, input_cnt: usize) !@This() {
            var inputs: ArrayList(bool) = .empty;
            try inputs.appendNTimes(gpa, false, input_cnt);

            var out: @This() = .{
                .kind = kind,
                .inputs = inputs,
                .output = undefined,
            };

            out.update();
            return out;
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            self.inputs.deinit(gpa);
            self.* = undefined;
        }

        pub fn update(self: *@This()) void {
            self.output = self.inputs.items[0];

            for (self.inputs.items[1..]) |b| {
                self.output = switch (self.kind) {
                    .@"and" => self.output and b,
                    .nand => !(self.output and b),
                    .@"or" => self.output or b,
                    .nor => !(self.output or b),
                    .xor => self.output ^ b,
                };
            }
        }
    },
    not_gate: struct {
        in: bool,
        out: bool,

        pub const init: @This() = .{
            .in = false,
            .out = true,
        };

        pub fn update(self: *@This()) void {
            self.out = !self.in;
        }
    },
    custom: CustomModuleInstance,

    pub fn fromModule(gpa: Allocator, module: *const Module) error{OutOfMemory}!Self {
        return switch (module.*) {
            .logic_gate => |gate| .{ .logic_gate = try .init(gpa, gate.kind, gate.input_cnt) },
            .not_gate => .{ .not_gate = .init },
            .custom => |mod_key| .{ .custom = try .fromCustomModule(gpa, mod_key) },
        };
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        switch (self.*) {
            .logic_gate => |*gate| gate.deinit(gpa),
            .not_gate => {},
            .custom => |*custom| custom.deinit(gpa),
        }
    }

    pub fn readOutput(self: *const Self, output: CustomModule.ChildOutputRef.OutputRef) []const bool {
        return switch (self.*) {
            .logic_gate => |*gate_inst| @as(*const [1]bool, @ptrCast(&gate_inst.output)),
            .not_gate => |*gate_inst| @as(*const [1]bool, @ptrCast(&gate_inst.out)),
            .custom => |*custom_inst| custom_inst.outputs.get(output.custom).?.*,
        };
    }

    pub fn update(self: *Self, gpa: Allocator) !void {
        switch (self.*) {
            .logic_gate => |*gate| gate.update(),
            .not_gate => |*gate| gate.update(),
            .custom => |*custom| try custom.update(gpa),
        }
    }
};

const QueueEntry = struct {
    const Self = @This();

    time: u64,
    dest: WireDest,
    src_values: []bool,

    pub fn cmp(ctx: void, self: Self, other: Self) Order {
        _ = ctx;
        return std.math.order(other.time, self.time);
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        gpa.free(self.src_values);
        self.* = undefined;
    }
};

pub const CustomModuleInstance = struct {
    const Self = @This();

    mod_key: CustomModule.Key,
    inputs: SecondaryMap(CustomModule.InputKey, []bool),
    outputs: SecondaryMap(CustomModule.OutputKey, []bool),
    children: SecondaryMap(CustomModule.Child.Key, ModuleInstance),
    queue: PriorityQueue(QueueEntry, void, QueueEntry.cmp),

    pub fn fromCustomModule(gpa: Allocator, mod_key: CustomModule.Key) !Self {
        const mod = globals.modules.get(mod_key).?;

        var out: Self = .{
            .mod_key = mod_key,
            .inputs = .empty,
            .outputs = .empty,
            .children = .empty,
            .queue = .init(gpa, {}),
        };

        var input_iter = mod.inputs.const_iterator();
        while (input_iter.next()) |entry| {
            const values = try gpa.alloc(bool, entry.val.width);
            @memset(values, false);
            _ = try out.inputs.put(gpa, entry.key, values);
        }

        var output_iter = mod.outputs.const_iterator();
        while (output_iter.next()) |entry| {
            const values = try gpa.alloc(bool, entry.val.width);
            @memset(values, false);
            _ = try out.outputs.put(gpa, entry.key, values);
        }

        var children_iter = mod.children.const_iterator();
        while (children_iter.next()) |entry| {
            const child_key = entry.key;
            const child = entry.val;

            const child_inst: ModuleInstance = try .fromModule(gpa, &child.mod);
            _ = try out.children.put(gpa, child_key, child_inst);

            var wire_iter = mod.wires.const_iterator();
            while (wire_iter.nextValue()) |wire| {
                if (wire.from == .child_output and wire.from.child_output.child_key.equals(child_key)) {
                    const from_values = out.readWireSrc(wire.from);
                    try out.writeWireDest(gpa, wire.to, from_values, 0);
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

        for (self.queue.items) |*entry|
            entry.deinit(gpa);

        self.inputs.deinit(gpa);
        self.outputs.deinit(gpa);
        self.children.deinit(gpa);
        self.queue.deinit();

        self.* = undefined;
    }

    const AffectedOutput = struct {
        time: u64,
        output_key: CustomModule.OutputKey,
    };

    fn writeChildInput(self: *Self, gpa: Allocator, ref: CustomModule.ChildInputRef, src_values: []const bool, time: u64) !void {
        if (self.children.get(ref.child_key)) |child_inst| {
            switch (child_inst.*) {
                .logic_gate => |*gate_inst| {
                    assert(src_values.len == 1);

                    if (gate_inst.inputs.items[ref.input.logic_gate] != src_values[0]) {
                        gate_inst.inputs.items[ref.input.logic_gate] = src_values[0];

                        const prev_output = gate_inst.output;
                        gate_inst.update();

                        if (gate_inst.output != prev_output) {
                            const gate_delay = 10;

                            try self.propagateFromWireSrc(gpa, .{
                                .child_output = .{
                                    .child_key = ref.child_key,
                                    .output = .logic_gate,
                                },
                            }, time + gate_delay);
                        }
                    }
                },
                .not_gate => |*gate_inst| {
                    assert(src_values.len == 1);

                    if (gate_inst.in != src_values[0]) {
                        gate_inst.in = src_values[0];
                        gate_inst.update();

                        const gate_delay = 5;

                        try self.propagateFromWireSrc(gpa, .{
                            .child_output = .{
                                .child_key = ref.child_key,
                                .output = .not_gate,
                            },
                        }, time + gate_delay);
                    }
                },
                .custom => |*custom_inst| try custom_inst.writeInput(gpa, ref.input.custom, src_values, time),
            }
        }
    }

    fn simulateChild(self: *Self, gpa: Allocator, child_key: CustomModule.Child.Key, max_time: u64) !void {
        const child_inst = self.children.get(child_key).?;
        if (child_inst.* != .custom)
            return;

        const child_affected = try child_inst.custom.simulate(gpa, max_time);
        defer gpa.free(child_affected);

        for (child_affected) |affected| {
            try self.propagateFromWireSrc(gpa, .{
                .child_output = .{
                    .child_key = child_key,
                    .output = .{ .custom = affected.output_key },
                },
            }, affected.time);
        }
    }

    pub fn simulate(self: *Self, gpa: Allocator, process_time: u64) error{OutOfMemory}![]AffectedOutput {
        var affected_outputs: ArrayList(AffectedOutput) = .empty;

        while (self.queue.peek()) |*entry_peek| {
            if (entry_peek.time >= process_time)
                break;

            var entry = self.queue.remove();
            defer entry.deinit(gpa);

            const src_values = entry.src_values;

            switch (entry.dest) {
                .top_output => |output_key| {
                    const output = self.outputs.get(output_key).?.*;

                    if (!std.mem.eql(bool, output, src_values)) {
                        @memcpy(output, src_values);
                        try affected_outputs.append(gpa, .{
                            .time = entry.time,
                            .output_key = output_key,
                        });
                    }
                },
                .child_input => |ref| try self.writeChildInput(gpa, ref, src_values, entry.time),
            }
        }

        var children_iter = self.children.iterator();
        while (children_iter.nextKey()) |child_key|
            try self.simulateChild(gpa, child_key, process_time);

        // Note that this doesn't affect the order of priorities within the queue
        for (self.queue.items) |*entry|
            entry.time -= process_time;

        return try affected_outputs.toOwnedSlice(gpa);
    }

    pub fn propagateFromWireSrc(self: *Self, gpa: Allocator, src: WireSrc, time: u64) !void {
        const self_mod = globals.modules.get(self.mod_key).?;
        const values = self.readWireSrc(src);

        var wire_iter = self_mod.wires.const_iterator();
        while (wire_iter.nextValue()) |wire| {
            if (wire.from.equals(&src))
                try self.writeWireDest(gpa, wire.to, values, time);
        }
    }

    pub fn writeInput(self: *Self, gpa: Allocator, input_key: CustomModule.InputKey, values: []const bool, time: u64) !void {
        const input_values = self.inputs.get(input_key).?.*;

        if (!std.mem.eql(bool, input_values, values)) {
            @memcpy(input_values, values);
            try self.propagateFromWireSrc(gpa, .{ .top_input = input_key }, time);
        }
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

    pub fn writeWireDest(self: *Self, gpa: Allocator, dest: WireDest, values: []const bool, time: u64) !void {
        try self.queue.add(.{
            .dest = dest,
            .time = time,
            .src_values = try gpa.dupe(bool, values),
        });
    }
};
