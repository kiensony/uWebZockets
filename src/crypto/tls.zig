const std = @import("std");
const c = @import("c");

const AlpnCallback = *const fn (
    ?*c.SSL,
    [*c][*c]const u8,
    [*c]u8,
    [*c]const u8,
    c_uint,
    ?*anyopaque,
) callconv(.c) c_int;

pub const TlsContext = struct {
    ctx: *c.SSL_CTX,

    // initializes tls context and loads certificates.
    pub fn init(cert_path: [:0]const u8, key_path: [:0]const u8) !TlsContext {
        return init_with_alpn(cert_path, key_path, select_http1_alpn);
    }

    pub fn init_http3(cert_path: [:0]const u8, key_path: [:0]const u8) !TlsContext {
        return init_with_alpn(cert_path, key_path, select_http3_alpn);
    }

    fn init_with_alpn(
        cert_path: [:0]const u8,
        key_path: [:0]const u8,
        callback: AlpnCallback,
    ) !TlsContext {
        c.CRYPTO_library_init();
        c.SSL_load_error_strings();

        const method = c.TLS_server_method();
        const ctx = c.SSL_CTX_new(method) orelse {
            return error.TlsContextCreationFailed;
        };
        errdefer c.SSL_CTX_free(ctx);

        if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_3_VERSION) != 1) {
            return error.ProtocolConfigurationFailed;
        }
        if (c.SSL_CTX_set_max_proto_version(ctx, c.TLS1_3_VERSION) != 1) {
            return error.ProtocolConfigurationFailed;
        }
        c.SSL_CTX_set_alpn_select_cb(ctx, callback, null);

        if (c.SSL_CTX_use_certificate_chain_file(ctx, cert_path.ptr) != 1) {
            return error.CertificateLoadFailed;
        }

        if (c.SSL_CTX_use_PrivateKey_file(ctx, key_path.ptr, c.SSL_FILETYPE_PEM) != 1) {
            return error.PrivateKeyLoadFailed;
        }

        if (c.SSL_CTX_check_private_key(ctx) != 1) {
            return error.KeyMismatch;
        }

        return TlsContext{ .ctx = ctx };
    }

    // frees the tls context.
    pub fn deinit(self: *TlsContext) void {
        c.SSL_CTX_free(self.ctx);
    }
};

fn select_http1_alpn(
    ssl: ?*c.SSL,
    out: [*c][*c]const u8,
    outlen: [*c]u8,
    in: [*c]const u8,
    inlen: c_uint,
    arg: ?*anyopaque,
) callconv(.c) c_int {
    _ = ssl;
    _ = arg;

    const protocols = "\x08http/1.1";

    if (c.SSL_select_next_proto(@ptrCast(out), outlen, protocols, protocols.len, in, inlen) != c.OPENSSL_NPN_NEGOTIATED) {
        return c.SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    return c.SSL_TLSEXT_ERR_OK;
}

fn select_http3_alpn(
    ssl: ?*c.SSL,
    out: [*c][*c]const u8,
    outlen: [*c]u8,
    in: [*c]const u8,
    inlen: c_uint,
    arg: ?*anyopaque,
) callconv(.c) c_int {
    _ = ssl;
    _ = arg;

    const protocols = "\x02h3";
    if (c.SSL_select_next_proto(@ptrCast(out), outlen, protocols, protocols.len, in, inlen) != c.OPENSSL_NPN_NEGOTIATED) {
        return c.SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    return c.SSL_TLSEXT_ERR_OK;
}
