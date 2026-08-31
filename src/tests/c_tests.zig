const std = @import("std");
const c = @import("c");

test "ensure boringssl compiles and links" {
    // check if boringssl constants and types are exposed properly.
    try std.testing.expect(c.TLS1_VERSION == 0x0301);
}

test "boringssl bio pair is bounded and bidirectional" {
    var first: ?*c.BIO = null;
    var second: ?*c.BIO = null;
    try std.testing.expectEqual(@as(c_int, 1), c.BIO_new_bio_pair(&first, 32, &second, 32));
    defer _ = c.BIO_free(first);
    defer _ = c.BIO_free(second);

    try std.testing.expectEqual(@as(usize, 32), c.BIO_ctrl_get_write_guarantee(first));
    try std.testing.expectEqual(@as(c_int, 4), c.BIO_write(first, "test", 4));

    var output: [4]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 4), c.BIO_read(second, &output, output.len));
    try std.testing.expectEqualStrings("test", &output);
}

test "ensure lsquic compiles and links" {
    // check if lsquic constants are exposed.
    try std.testing.expect(c.LSQUIC_MAJOR_VERSION >= 3);
}

test "ensure libdeflate compiles and links" {
    // check if libdeflate functions can be called.
    const compressor = c.libdeflate_alloc_compressor(6);
    try std.testing.expect(compressor != null);
    c.libdeflate_free_compressor(compressor);
}
