pub const boot = @import("aarch64/boot.zig");
pub const time = @import("aarch64/time.zig");
pub const paging = @import("aarch64/paging.zig");
pub const io = @import("../util/mmio.zig");

const util = @import("aarch64/util.zig");
pub const wfi = util.wfi;
pub const halt = util.halt;
