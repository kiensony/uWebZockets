pub const State = struct {
    remaining: u3 = 0,
    lower: u8 = 0x80,
    upper: u8 = 0xbf,
};

pub fn validate_chunk(state: State, input: []const u8) ?State {
    var next = state;

    for (input) |byte| {
        if (next.remaining != 0) {
            if (byte < next.lower or byte > next.upper) return null;
            next.remaining -= 1;
            next.lower = 0x80;
            next.upper = 0xbf;
            continue;
        }

        if (byte <= 0x7f) continue;
        if (byte >= 0xc2 and byte <= 0xdf) {
            next.remaining = 1;
            continue;
        }
        if (byte == 0xe0) {
            next.remaining = 2;
            next.lower = 0xa0;
            continue;
        }
        if ((byte >= 0xe1 and byte <= 0xec) or (byte >= 0xee and byte <= 0xef)) {
            next.remaining = 2;
            continue;
        }
        if (byte == 0xed) {
            next.remaining = 2;
            next.upper = 0x9f;
            continue;
        }
        if (byte == 0xf0) {
            next.remaining = 3;
            next.lower = 0x90;
            continue;
        }
        if (byte >= 0xf1 and byte <= 0xf3) {
            next.remaining = 3;
            continue;
        }
        if (byte == 0xf4) {
            next.remaining = 3;
            next.upper = 0x8f;
            continue;
        }
        return null;
    }
    return next;
}

pub fn is_complete(state: State) bool {
    return state.remaining == 0;
}
