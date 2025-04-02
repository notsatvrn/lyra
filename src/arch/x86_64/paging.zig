const util = @import("util.zig");

const log = @import("../../log.zig");
const logger = log.Logger{ .name = "x86-64/paging" };

var kcr3: u64 = undefined; // kernel page table
pub inline fn saveTable() void {
    kcr3 = util.getRegister(u64, "cr3");
}
