const structs = @import("./structs/structs.zig");
const core = @import("./core.zig");

const SlotMap = structs.SlotMap;
const CustomModule = core.CustomModule;

pub var modules: SlotMap(CustomModule) = .empty;
