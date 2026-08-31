const std = @import("std");
const c = @import("c");

pub const available = true;
pub const max_udp_payload_size: usize = 2048;

var global_lock: std.atomic.Mutex = .unlocked;
var global_references: usize = 0;

pub fn acquire_global() !void {
    lock_global();
    defer global_lock.unlock();

    if (global_references == 0) {
        if (c.lsquic_global_init(c.LSQUIC_GLOBAL_SERVER) != 0) {
            return error.LsquicGlobalInitFailed;
        }
    }
    if (global_references == std.math.maxInt(usize)) {
        return error.ReferenceCountOverflow;
    }
    global_references += 1;
}

pub fn release_global() void {
    lock_global();
    defer global_lock.unlock();

    std.debug.assert(global_references != 0);
    global_references -= 1;
    if (global_references == 0) c.lsquic_global_cleanup();
}

fn lock_global() void {
    while (!global_lock.tryLock()) std.atomic.spinLoopHint();
}

pub const Sockaddr = struct {
    storage: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage),
    length: c.socklen_t = 0,

    pub fn init(address: std.Io.net.IpAddress) Sockaddr {
        var result = Sockaddr{};

        switch (address) {
            .ip4 => |value| {
                const sockaddr: *std.posix.sockaddr.in = @ptrCast(@alignCast(&result.storage));
                sockaddr.* = std.mem.zeroes(std.posix.sockaddr.in);
                sockaddr.family = std.posix.AF.INET;
                sockaddr.port = std.mem.nativeToBig(u16, value.port);
                sockaddr.addr = @bitCast(value.bytes);
                result.length = @sizeOf(std.posix.sockaddr.in);
            },
            .ip6 => |value| {
                const sockaddr: *std.posix.sockaddr.in6 = @ptrCast(@alignCast(&result.storage));
                sockaddr.* = std.mem.zeroes(std.posix.sockaddr.in6);
                sockaddr.family = std.posix.AF.INET6;
                sockaddr.port = std.mem.nativeToBig(u16, value.port);
                sockaddr.addr = value.bytes;
                result.length = @sizeOf(std.posix.sockaddr.in6);
            },
        }
        return result;
    }

    pub fn ptr(self: *const Sockaddr) [*c]const c.struct_sockaddr {
        return @ptrCast(&self.storage);
    }
};

pub fn send_packets(
    fd: std.posix.socket_t,
    specs: [*c]const c.lsquic_out_spec,
    count: c_uint,
) c_int {
    if (fd < 0) return fail_with_errno(.BADF);
    if (specs == null) return fail_with_errno(.INVAL);
    if (count == 0) return 0;

    const packet_count: usize = @intCast(count);
    var sent: usize = 0;
    packet_loop: while (sent < packet_count) : (sent += 1) {
        const spec = specs[sent];
        if (spec.dest_sa == null or spec.iov == null or spec.iovlen == 0) {
            set_errno(.INVAL);
            break;
        }

        var total_size: usize = 0;
        var index: usize = 0;
        while (index < spec.iovlen) : (index += 1) {
            const part_size = spec.iov[index].iov_len;
            if (part_size > max_udp_payload_size -| total_size) break;
            total_size += part_size;
        }
        if (index != spec.iovlen or total_size == 0) {
            set_errno(.MSGSIZE);
            break;
        }

        const address_length: c.socklen_t = switch (spec.dest_sa.*.sa_family) {
            c.AF_INET => @sizeOf(c.struct_sockaddr_in),
            c.AF_INET6 => @sizeOf(c.struct_sockaddr_in6),
            else => {
                set_errno(.AFNOSUPPORT);
                break :packet_loop;
            },
        };
        var message = c.struct_msghdr{
            .msg_name = @ptrCast(@constCast(spec.dest_sa)),
            .msg_namelen = address_length,
            .msg_iov = spec.iov,
            .msg_iovlen = spec.iovlen,
        };
        const written = c.sendmsg(fd, &message, c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
        if (written < 0) break;
        if (@as(usize, @intCast(written)) != total_size) {
            set_errno(.IO);
            break;
        }
    }

    if (sent == 0) return -1;
    return @intCast(sent);
}

fn fail_with_errno(err: std.c.E) c_int {
    set_errno(err);
    return -1;
}

fn set_errno(err: std.c.E) void {
    std.c._errno().* = @intFromEnum(err);
}

test "quic: sockaddr conversion preserves address family and port" {
    const input = try std.Io.net.IpAddress.parse("127.0.0.1", 8443);
    const address = Sockaddr.init(input);
    const sockaddr: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&address.storage));

    try std.testing.expectEqual(std.posix.AF.INET, sockaddr.family);
    try std.testing.expectEqual(@as(u16, 8443), std.mem.bigToNative(u16, sockaddr.port));
    try std.testing.expectEqual(@as(c.socklen_t, @sizeOf(std.posix.sockaddr.in)), address.length);
}
