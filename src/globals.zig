const std = @import("std");
const rl = @import("raylib");
const structs = @import("./structs/structs.zig");
const core = @import("./core.zig");
const user_dirs = @import("./user_dirs.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Color = rl.Color;
const Vector2 = rl.Vector2;
const SlotMap = structs.SlotMap;
const SecondaryMap = structs.SecondaryMap;
const CustomModule = core.CustomModule;
const Module = core.Module;

pub var modules: SlotMap(CustomModule) = .empty;

pub const ModuleJson = union(enum) {
    const Self = @This();

    logic_gate: Module.LogicGate,
    not_gate,
    split: Module.Split,
    join: Module.Join,
    clock: Module.Clock,
    custom: usize,

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        switch (self.*) {
            .join => |*join| join.deinit(gpa),
            else => {},
        }
        self.* = undefined;
    }
};

const CustomModuleJson = struct {
    const Self = @This();

    pub const Child = struct {
        pos: Vector2,
        mod: ModuleJson,

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            self.mod.deinit(gpa);
            self.* = undefined;
        }
    };

    pub const WireSrc = union(enum) {
        top_input: usize,
        child_output: struct {
            child_key: usize,
            output: union(enum) {
                logic_gate,
                not_gate,
                split,
                join,
                clock,
                custom: usize,
            },
        },
    };

    pub const WireDest = union(enum) {
        top_output: usize,
        child_input: struct {
            child_key: usize,
            input: union(enum) {
                logic_gate: ?usize,
                not_gate,
                split,
                join: usize,
                custom: usize,
            },
        },
    };

    pub const Wire = struct {
        from: WireSrc,
        points: []Vector2,
        to: WireDest,

        pub fn deinit(self: @This(), gpa: Allocator) void {
            gpa.free(self.points);
        }
    };

    name: []u8,
    color: u32,
    inputs: []CustomModule.Port,
    outputs: []CustomModule.Port,
    children: []Child,
    wires: []Wire,

    pub fn deinit(self: Self, gpa: Allocator) void {
        for (self.inputs) |*input|
            input.deinit(gpa);

        for (self.outputs) |*output|
            output.deinit(gpa);

        for (self.children) |*child|
            child.deinit(gpa);

        for (self.wires) |*wire|
            wire.deinit(gpa);

        gpa.free(self.name);
        gpa.free(self.inputs);
        gpa.free(self.outputs);
        gpa.free(self.children);
        gpa.free(self.wires);
    }
};

fn createKeyIndexMaps(
    gpa: Allocator,
    mod_idxs: *SecondaryMap(CustomModule.Key, usize),
    input_idxs_all: *SecondaryMap(CustomModule.Key, SecondaryMap(CustomModule.PortKey, usize)),
    output_idxs_all: *SecondaryMap(CustomModule.Key, SecondaryMap(CustomModule.PortKey, usize)),
) !void {
    var mods_iter = modules.constIterator();
    var i: usize = 0;

    while (mods_iter.next()) |mod_entry| : (i += 1) {
        const mod_key = mod_entry.key;
        const mod = mod_entry.val;
        _ = try mod_idxs.put(gpa, mod_key, i);

        var input_idxs: SecondaryMap(CustomModule.PortKey, usize) = .empty;
        var inputs_iter = mod.inputs.constIterator();
        var j: usize = 0;

        while (inputs_iter.nextKey()) |input_key| : (j += 1)
            _ = try input_idxs.put(gpa, input_key, j);

        var output_idxs: SecondaryMap(CustomModule.PortKey, usize) = .empty;
        var outputs_iter = mod.outputs.constIterator();
        j = 0;

        while (outputs_iter.nextKey()) |output_key| : (j += 1)
            _ = try output_idxs.put(gpa, output_key, j);

        _ = try input_idxs_all.put(gpa, mod_key, input_idxs);
        _ = try output_idxs_all.put(gpa, mod_key, output_idxs);
    }
}

fn createModuleJsonList(gpa: Allocator) ![]CustomModuleJson {
    var mod_idxs: SecondaryMap(CustomModule.Key, usize) = .empty;
    defer mod_idxs.deinit(gpa);

    var input_idxs_all: SecondaryMap(CustomModule.Key, SecondaryMap(CustomModule.PortKey, usize)) = .empty;
    defer input_idxs_all.deinit(gpa);
    defer {
        var iter = input_idxs_all.iterator();
        while (iter.nextValue()) |idxs|
            idxs.deinit(gpa);
    }

    var output_idxs_all: SecondaryMap(CustomModule.Key, SecondaryMap(CustomModule.PortKey, usize)) = .empty;
    defer output_idxs_all.deinit(gpa);
    defer {
        var iter = output_idxs_all.iterator();
        while (iter.nextValue()) |idxs|
            idxs.deinit(gpa);
    }

    try createKeyIndexMaps(gpa, &mod_idxs, &input_idxs_all, &output_idxs_all);

    var mods_json: ArrayList(CustomModuleJson) = .empty;

    var mods_iter = modules.iterator();
    while (mods_iter.next()) |mod_entry| {
        const mod_key = mod_entry.key;
        const mod = mod_entry.val;

        const output_idxs = output_idxs_all.getPtr(mod_key).?;
        const input_idxs = input_idxs_all.getPtr(mod_key).?;

        var inputs_json = try gpa.alloc(CustomModule.Port, mod.inputs.count);
        var inputs_iter = mod.inputs.constIterator();

        while (inputs_iter.next()) |entry| {
            const input_key = entry.key;
            const input = entry.val;
            const idx = input_idxs.getPtr(input_key).?.*;

            inputs_json[idx] = .{
                .name = if (input.name) |name| try gpa.dupeZ(u8, name) else null,
                .order = input.order,
                .width = input.width,
            };
        }

        var outputs_json = try gpa.alloc(CustomModule.Port, mod.outputs.count);
        var outputs_iter = mod.outputs.constIterator();

        while (outputs_iter.next()) |entry| {
            const output_key = entry.key;
            const output = entry.val;
            const idx = output_idxs.getPtr(output_key).?.*;

            outputs_json[idx] = .{
                .name = if (output.name) |name| try gpa.dupeZ(u8, name) else null,
                .order = output.order,
                .width = output.width,
            };
        }

        var children_json = try gpa.alloc(CustomModuleJson.Child, mod.children.count);
        var child_idxs: SecondaryMap(CustomModule.Child.Key, usize) = .empty;
        defer child_idxs.deinit(gpa);

        var children_iter = mod.children.constIterator();
        var i: usize = 0;

        while (children_iter.next()) |child_entry| : (i += 1) {
            const child_key = child_entry.key;
            const child = child_entry.val;

            _ = try child_idxs.put(gpa, child_key, i);

            children_json[i] = .{
                .pos = child.pos,
                .mod = switch (child.mod) {
                    .logic_gate => |gate| .{ .logic_gate = gate },
                    .not_gate => .not_gate,
                    .split => |split| .{ .split = split },
                    .join => |join| .{ .join = try join.clone(gpa) },
                    .clock => |clock| .{ .clock = clock },
                    .custom => |mkey| .{ .custom = mod_idxs.getPtr(mkey).?.* },
                },
            };
        }

        var wires_json = try gpa.alloc(CustomModuleJson.Wire, mod.wires.count);

        var wire_iter = mod.wires.constIterator();
        i = 0;

        while (wire_iter.nextValue()) |wire| : (i += 1) {
            wires_json[i] = .{
                .from = switch (wire.from) {
                    .top_input => |input_key| .{ .top_input = input_idxs.getPtr(input_key).?.* },
                    .child_output => |ref| .{
                        .child_output = .{
                            .child_key = child_idxs.getPtr(ref.child_key).?.*,
                            .output = switch (ref.output) {
                                .logic_gate => .logic_gate,
                                .not_gate => .not_gate,
                                .split => .split,
                                .join => .join,
                                .clock => .clock,
                                .custom => |output_key| blk: {
                                    const child_mod_key = mod.children.getPtr(ref.child_key).?.mod.custom;
                                    const child_output_idxs = output_idxs_all.getPtr(child_mod_key).?;
                                    break :blk .{ .custom = child_output_idxs.getPtr(output_key).?.* };
                                },
                            },
                        },
                    },
                },
                .to = switch (wire.to) {
                    .top_output => |key| .{ .top_output = output_idxs.getPtr(key).?.* },
                    .child_input => |ref| .{
                        .child_input = .{
                            .child_key = child_idxs.getPtr(ref.child_key).?.*,
                            .input = switch (ref.input) {
                                .logic_gate => |input_idx| .{ .logic_gate = input_idx },
                                .not_gate => .not_gate,
                                .split => .split,
                                .join => |input_idx| .{ .join = input_idx },
                                .custom => |input_key| blk: {
                                    const child_mod_key = mod.children.getPtr(ref.child_key).?.mod.custom;
                                    const child_input_idxs = input_idxs_all.getPtr(child_mod_key).?;
                                    break :blk .{ .custom = child_input_idxs.getPtr(input_key).?.* };
                                },
                            },
                        },
                    },
                },
                .points = try gpa.dupe(Vector2, wire.points),
            };
        }

        const mod_json: CustomModuleJson = .{
            .name = try gpa.dupe(u8, mod.name),
            .color = @bitCast(mod.color.toInt()),
            .inputs = inputs_json,
            .outputs = outputs_json,
            .children = children_json,
            .wires = wires_json,
        };

        try mods_json.append(gpa, mod_json);
    }

    return try mods_json.toOwnedSlice(gpa);
}

pub fn createModuleJsonListString(gpa: Allocator) ![]u8 {
    const mods_json = try createModuleJsonList(gpa);
    defer gpa.free(mods_json);
    defer for (mods_json) |mod| mod.deinit(gpa);

    var writer: std.io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    try writer.writer.print("{f}", .{std.json.fmt(mods_json, .{ .whitespace = .indent_2 })});
    return try gpa.dupe(u8, writer.written());
}

fn modulesFilename(gpa: Allocator) ![:0]u8 {
    return try user_dirs.dataDirFileZ(gpa, "modules.json");
}

pub fn saveCustomModules(gpa: Allocator) !void {
    const filename = try modulesFilename(gpa);
    defer gpa.free(filename);

    if (rl.makeDirectory(rl.getDirectoryPath(filename)) != 0)
        return error.MakeDirectoryError;

    const data_str = try createModuleJsonListString(gpa);
    defer gpa.free(data_str);

    if (!rl.saveFileData(filename, data_str))
        return error.SaveFileDataError;
}

pub fn loadCustomModulesFromStr(gpa: Allocator, data_str: []const u8) !void {
    const parsed = try std.json.parseFromSlice([]CustomModuleJson, gpa, data_str, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const mods_json: []CustomModuleJson = parsed.value;

    const mod_keys = try gpa.alloc(CustomModule.Key, mods_json.len);
    defer gpa.free(mod_keys);

    const input_keys_all = try gpa.alloc([]CustomModule.PortKey, mods_json.len);
    defer gpa.free(input_keys_all);
    defer for (input_keys_all) |input_keys| gpa.free(input_keys);

    const output_keys_all = try gpa.alloc([]CustomModule.PortKey, mods_json.len);
    defer gpa.free(output_keys_all);
    defer for (output_keys_all) |output_keys| gpa.free(output_keys);

    for (0.., mods_json) |i, mod_json| {
        input_keys_all[i] = try gpa.alloc(CustomModule.PortKey, mod_json.inputs.len);
        var inputs: SlotMap(CustomModule.Port) = try .initCapacity(gpa, mod_json.inputs.len);

        for (0.., mod_json.inputs) |j, input| {
            input_keys_all[i][j] = try inputs.put(gpa, .{
                .name = if (input.name) |name| try gpa.dupeZ(u8, name) else null,
                .order = input.order,
                .width = input.width,
            });
        }

        output_keys_all[i] = try gpa.alloc(CustomModule.PortKey, mod_json.outputs.len);
        var outputs: SlotMap(CustomModule.Port) = try .initCapacity(gpa, mod_json.outputs.len);

        for (0.., mod_json.outputs) |j, output| {
            output_keys_all[i][j] = try outputs.put(gpa, .{
                .name = if (output.name) |name| try gpa.dupeZ(u8, name) else null,
                .order = output.order,
                .width = output.width,
            });
        }

        mod_keys[i] = try modules.put(gpa, .{
            .name = undefined,
            .color = undefined,
            .inputs = inputs,
            .outputs = outputs,
            .children = undefined,
            .wires = undefined,
        });
    }

    for (0.., mods_json) |i, mod_json| {
        const input_keys = input_keys_all[i];
        const output_keys = output_keys_all[i];

        var children: SlotMap(CustomModule.Child) = try .initCapacity(gpa, mod_json.children.len);
        const child_keys = try gpa.alloc(CustomModule.Child.Key, mod_json.children.len);
        defer gpa.free(child_keys);

        for (0.., mod_json.children) |j, child_json| {
            const child: CustomModule.Child = .{
                .pos = child_json.pos,
                .mod = switch (child_json.mod) {
                    .logic_gate => |gate| .{ .logic_gate = gate },
                    .not_gate => .not_gate,
                    .split => |split| .{ .split = split },
                    .join => |join| .{ .join = try join.clone(gpa) },
                    .clock => |clock| .{ .clock = clock },
                    .custom => |mod_idx| .{ .custom = mod_keys[mod_idx] },
                },
            };

            child_keys[j] = try children.put(gpa, child);
        }

        var wires: SlotMap(CustomModule.Wire) = try .initCapacity(gpa, mod_json.wires.len);

        for (mod_json.wires) |wire_json| {
            const wire: CustomModule.Wire = .{
                .from = switch (wire_json.from) {
                    .top_input => |input_idx| .{ .top_input = input_keys[input_idx] },
                    .child_output => |ref| .{
                        .child_output = .{
                            .child_key = child_keys[ref.child_key],
                            .output = switch (ref.output) {
                                .logic_gate => .logic_gate,
                                .not_gate => .not_gate,
                                .split => .split,
                                .join => .join,
                                .clock => .clock,
                                .custom => |output_idx| blk: {
                                    const child_mod_idx = mod_json.children[ref.child_key].mod.custom;
                                    const child_output_keys = output_keys_all[child_mod_idx];
                                    break :blk .{ .custom = child_output_keys[output_idx] };
                                },
                            },
                        },
                    },
                },
                .to = switch (wire_json.to) {
                    .top_output => |output_idx| .{ .top_output = output_keys[output_idx] },
                    .child_input => |ref| .{
                        .child_input = .{
                            .child_key = child_keys[ref.child_key],
                            .input = switch (ref.input) {
                                .logic_gate => |input_idx| .{ .logic_gate = input_idx },
                                .not_gate => .not_gate,
                                .split => .split,
                                .join => |input_idx| .{ .join = input_idx },
                                .custom => |input_idx| blk: {
                                    const child_mod_idx = mod_json.children[ref.child_key].mod.custom;
                                    const child_input_keys = input_keys_all[child_mod_idx];
                                    break :blk .{ .custom = child_input_keys[input_idx] };
                                },
                            },
                        },
                    },
                },
                .points = try gpa.dupe(Vector2, wire_json.points),
            };

            _ = try wires.put(gpa, wire);
        }

        const key = mod_keys[i];
        const mod = modules.getPtr(key).?;

        modules.getPtr(key).?.* = .{
            .name = try gpa.dupeZ(u8, mod_json.name),
            .color = .fromInt(mod_json.color),
            .inputs = mod.inputs,
            .outputs = mod.outputs,
            .children = children,
            .wires = wires,
        };
    }
}

pub fn loadCustomModules(gpa: Allocator) !void {
    const filename = try modulesFilename(gpa);
    defer gpa.free(filename);

    if (!rl.fileExists(filename)) {
        std.log.info("Modules file not found.", .{});
        return;
    }

    std.log.info("Modules file found. Loading custom modules...", .{});

    const data_str = try rl.loadFileData(filename);
    defer rl.memFree(data_str.ptr);

    try loadCustomModulesFromStr(gpa, data_str);
}
