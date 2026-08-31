#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <openssl/base.h>
#undef OPENSSL_GNUC_CLANG_PRAGMA
#define OPENSSL_GNUC_CLANG_PRAGMA(arg)

#include <openssl/ssl.h>
#include <openssl/crypto.h>
#include <lsxpack_header.h>
#include <lsquic.h>
#include <libdeflate.h>
#include <zlib.h>

/* translate-c cannot represent lsxpack_header's 8-bit enum bitfield. */
struct uz_lsxpack_header {
    char *buf;
    uint32_t name_hash;
    uint32_t nameval_hash;
    lsxpack_offset_t name_offset;
    lsxpack_offset_t val_offset;
    lsxpack_strlen_t name_len;
    lsxpack_strlen_t val_len;
    uint16_t chain_next_idx;
    uint8_t hpack_index;
    uint8_t qpack_index;
    uint8_t app_index;
    uint8_t flags;
    uint8_t indexed_type;
    uint8_t dec_overhead;
};
