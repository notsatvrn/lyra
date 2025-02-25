pub const oldschoolPGC = @import("fonts/oldschoolPGC.zig");

// some fonts will get displayed backwards without this
// didn't feel like manually correcting it lol
pub fn reverse(font: [256][16]u8) [256][16]u8 {
    @setEvalBranchQuota(10000);

    var out = font;
    for (0..256) |i| {
        const old = out[i];
        var new = [_]u8{0} ** 16;
        for (0..16) |j|
            new[j] = @bitReverse(old[j]);

        out[i] = new;
    }

    return out;
}
