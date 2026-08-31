const zslay = @import("zslay");

const Vector = @Vector(16, u8);

pub fn apply(buffer: []u8, masking_key: zslay.MaskingKey, position: u64) void {
    if (buffer.len == 0) return;

    var key_bytes: [16]u8 = undefined;
    for (&key_bytes, 0..) |*byte, index| {
        const key_index: usize = @intCast((position + @as(u64, @intCast(index))) % @as(u64, masking_key.len));
        byte.* = masking_key[key_index];
    }
    const key_vector: Vector = key_bytes;

    var offset: usize = 0;
    while (offset + @sizeOf(Vector) <= buffer.len) : (offset += @sizeOf(Vector)) {
        const vector: *align(1) Vector = @ptrCast(buffer[offset..].ptr);
        vector.* = vector.* ^ key_vector;
    }

    while (offset < buffer.len) : (offset += 1) {
        const key_index: usize = @intCast((position + @as(u64, @intCast(offset))) % @as(u64, masking_key.len));
        buffer[offset] ^= masking_key[key_index];
    }
}
