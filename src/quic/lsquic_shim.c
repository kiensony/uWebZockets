#include "../c.h"

_Static_assert(sizeof(struct uz_lsxpack_header) == sizeof(struct lsxpack_header),
               "lsxpack header ABI size mismatch");
_Static_assert(_Alignof(struct uz_lsxpack_header) == _Alignof(struct lsxpack_header),
               "lsxpack header ABI alignment mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, buf) ==
                   offsetof(struct lsxpack_header, buf),
               "lsxpack buf ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, name_hash) ==
                   offsetof(struct lsxpack_header, name_hash),
               "lsxpack name_hash ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, nameval_hash) ==
                   offsetof(struct lsxpack_header, nameval_hash),
               "lsxpack nameval_hash ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, name_offset) ==
                   offsetof(struct lsxpack_header, name_offset),
               "lsxpack name_offset ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, val_offset) ==
                   offsetof(struct lsxpack_header, val_offset),
               "lsxpack val_offset ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, name_len) ==
                   offsetof(struct lsxpack_header, name_len),
               "lsxpack name_len ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, val_len) ==
                   offsetof(struct lsxpack_header, val_len),
               "lsxpack val_len ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, chain_next_idx) ==
                   offsetof(struct lsxpack_header, chain_next_idx),
               "lsxpack chain_next_idx ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, hpack_index) ==
                   offsetof(struct lsxpack_header, hpack_index),
               "lsxpack hpack_index ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, qpack_index) ==
                   offsetof(struct lsxpack_header, qpack_index),
               "lsxpack qpack_index ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, app_index) ==
                   offsetof(struct lsxpack_header, app_index),
               "lsxpack app_index ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, indexed_type) ==
                   offsetof(struct lsxpack_header, indexed_type),
               "lsxpack indexed_type ABI offset mismatch");
_Static_assert(offsetof(struct uz_lsxpack_header, dec_overhead) ==
                   offsetof(struct lsxpack_header, dec_overhead),
               "lsxpack dec_overhead ABI offset mismatch");
