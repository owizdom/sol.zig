// Solana shred format: 1228-byte packets that carry block data over Turbine.
// Data shreds carry transaction/entry data; coding shreds carry Reed-Solomon parity.
const std = @import("std");
const types   = @import("types");
const keypair = @import("keypair");

// ── Constants ────────────────────────────────────────────────────────────────

pub const SHRED_SIZE:         usize = 1228;
pub const SIGNATURE_BYTES:    usize = 64;
pub const SHRED_DATA_OFFSET:  usize = 88;  // signature(64) + common_header(24)
pub const DATA_PAYLOAD_SIZE:  usize = SHRED_SIZE - SHRED_DATA_OFFSET - 5; // 5 bytes data header
pub const CODING_PAYLOAD_SIZE: usize = SHRED_SIZE - SHRED_DATA_OFFSET - 6; // 6 bytes coding header

pub const DATA_SHREDS_PER_FEC:   u16 = 32;
pub const CODING_SHREDS_PER_FEC: u16 = 32;

// ── Shred variant ────────────────────────────────────────────────────────────

pub const ShredVariant = enum(u8) {
    legacy_code = 0x0b,
    legacy_data = 0x0a,
    merkle_code = 0x40,
    merkle_data = 0x80,
};

// ── Common header (present in all shreds) ───────────────────────────────────

pub const CommonHeader = struct {
    signature:     [64]u8,
    shred_variant: u8,
    slot:          types.Slot,
    index:         u32,
    version:       u16,
    fec_set_index: u32,

    pub const SIZE: usize = 83; // 64 + 1 + 8 + 4 + 2 + 4

    pub fn serialize(self: CommonHeader, buf: *[SIZE]u8) void {
        @memcpy(buf[0..64], &self.signature);
        buf[64] = self.shred_variant;
        std.mem.writeInt(u64, buf[65..73], self.slot, .little);
        std.mem.writeInt(u32, buf[73..77], self.index, .little);
        std.mem.writeInt(u16, buf[77..79], self.version, .little);
        std.mem.writeInt(u32, buf[79..83], self.fec_set_index, .little);
    }

    pub fn deserialize(buf: *const [SIZE]u8) CommonHeader {
        return .{
            .signature     = buf[0..64].*,
            .shred_variant = buf[64],
            .slot          = std.mem.readInt(u64, buf[65..73], .little),
            .index         = std.mem.readInt(u32, buf[73..77], .little),
            .version       = std.mem.readInt(u16, buf[77..79], .little),
            .fec_set_index = std.mem.readInt(u32, buf[79..83], .little),
        };
    }
};

// ── Data shred header (follows common header) ────────────────────────────────

pub const DataHeader = struct {
    parent_offset: u16,   // slot - parent_slot
    flags:         u8,
    size:          u16,   // total shred size (including headers)

    pub const SIZE: usize = 5;
    pub const FLAG_DATA_COMPLETE_SHRED: u8 = 0x01;
    pub const FLAG_LAST_SHRED_IN_SLOT:  u8 = 0x02;

    pub fn serialize(self: DataHeader, buf: *[SIZE]u8) void {
        std.mem.writeInt(u16, buf[0..2], self.parent_offset, .little);
        buf[2] = self.flags;
        std.mem.writeInt(u16, buf[3..5], self.size, .little);
    }

    pub fn deserialize(buf: *const [SIZE]u8) DataHeader {
        return .{
            .parent_offset = std.mem.readInt(u16, buf[0..2], .little),
            .flags         = buf[2],
            .size          = std.mem.readInt(u16, buf[3..5], .little),
        };
    }
};

// ── Coding shred header ──────────────────────────────────────────────────────

pub const CodingHeader = struct {
    num_data_shreds:   u16,
    num_coding_shreds: u16,
    position:          u16,  // index within the FEC set

    pub const SIZE: usize = 6;

    pub fn serialize(self: CodingHeader, buf: *[6]u8) void {
        std.mem.writeInt(u16, buf[0..2], self.num_data_shreds, .little);
        std.mem.writeInt(u16, buf[2..4], self.num_coding_shreds, .little);
        std.mem.writeInt(u16, buf[4..6], self.position, .little);
    }
};

// ── Shred packet ─────────────────────────────────────────────────────────────

pub const Shred = struct {
    data: [SHRED_SIZE]u8,

    pub const Kind = enum { data, coding, unknown };

    pub fn kind(self: *const Shred) Kind {
        const v = self.data[64];
        return switch (v) {
            @intFromEnum(ShredVariant.legacy_data), @intFromEnum(ShredVariant.merkle_data) => .data,
            @intFromEnum(ShredVariant.legacy_code), @intFromEnum(ShredVariant.merkle_code) => .coding,
            else => .unknown,
        };
    }

    pub fn slot(self: *const Shred) types.Slot {
        return std.mem.readInt(u64, self.data[65..73], .little);
    }

    pub fn index(self: *const Shred) u32 {
        return std.mem.readInt(u32, self.data[73..77], .little);
    }

    pub fn fecSetIndex(self: *const Shred) u32 {
        return std.mem.readInt(u32, self.data[79..83], .little);
    }

    pub fn isLastInSlot(self: *const Shred) bool {
        if (self.kind() != .data) return false;
        return (self.data[SIGNATURE_BYTES + CommonHeader.SIZE + 2] &
                DataHeader.FLAG_LAST_SHRED_IN_SLOT) != 0;
    }

    /// Payload bytes (after all headers).
    pub fn payload(self: *const Shred) []const u8 {
        return switch (self.kind()) {
            .data   => self.data[SHRED_DATA_OFFSET + DataHeader.SIZE ..
                                  SHRED_DATA_OFFSET + DataHeader.SIZE + DATA_PAYLOAD_SIZE],
            .coding => self.data[SHRED_DATA_OFFSET + CodingHeader.SIZE ..
                                  SHRED_DATA_OFFSET + CodingHeader.SIZE + CODING_PAYLOAD_SIZE],
            .unknown => &self.data,
        };
    }
};

// ── Shred factory ────────────────────────────────────────────────────────────

pub const ShredFactory = struct {
    kp:      keypair.KeyPair,
    slot:    types.Slot,
    version: u16,

    pub fn init(kp: keypair.KeyPair, slot: types.Slot, version: u16) ShredFactory {
        return .{ .kp = kp, .slot = slot, .version = version };
    }

    /// Shred a block's data into data shreds. Caller owns returned slice.
    pub fn shredData(
        self:      *ShredFactory,
        data:      []const u8,
        parent_slot: types.Slot,
        allocator: std.mem.Allocator,
    ) ![]Shred {
        const payload_size = DATA_PAYLOAD_SIZE;
        const n_shreds = (data.len + payload_size - 1) / payload_size;
        if (n_shreds == 0) return &.{};

        const shreds = try allocator.alloc(Shred, n_shreds);

        for (shreds, 0..) |*sh, i| {
            sh.data = [_]u8{0} ** SHRED_SIZE;

            const hdr = CommonHeader{
                .signature     = [_]u8{0} ** 64, // filled after signing below
                .shred_variant = @intFromEnum(ShredVariant.merkle_data),
                .slot          = self.slot,
                .index         = @intCast(i),
                .version       = self.version,
                .fec_set_index = 0,
            };
            var ch_buf: [CommonHeader.SIZE]u8 = undefined;
            hdr.serialize(&ch_buf);
            @memcpy(sh.data[0..CommonHeader.SIZE], &ch_buf);

            const is_last = (i == n_shreds - 1);
            var flags: u8 = DataHeader.FLAG_DATA_COMPLETE_SHRED;
            if (is_last) flags |= DataHeader.FLAG_LAST_SHRED_IN_SLOT;

            const data_hdr = DataHeader{
                .parent_offset = @intCast(self.slot - parent_slot),
                .flags         = flags,
                .size          = @intCast(SHRED_DATA_OFFSET + DataHeader.SIZE + payload_size),
            };
            var dh_buf: [DataHeader.SIZE]u8 = undefined;
            data_hdr.serialize(&dh_buf);
            @memcpy(sh.data[CommonHeader.SIZE..][0..DataHeader.SIZE], &dh_buf);

            // Copy payload.
            const start = i * payload_size;
            const end   = @min(start + payload_size, data.len);
            @memcpy(sh.data[SHRED_DATA_OFFSET + DataHeader.SIZE..][0..end - start], data[start..end]);

            // Sign the shred (everything after the signature field).
            const sig = self.kp.sign(sh.data[SIGNATURE_BYTES..]) catch continue;
            @memcpy(sh.data[0..SIGNATURE_BYTES], &sig.bytes);
        }

        return shreds;
    }

    /// Verify the signature on a shred against a known validator pubkey.
    pub fn verify(sh: *const Shred, pubkey: types.Pubkey) bool {
        const sig = types.Signature{ .bytes = sh.data[0..SIGNATURE_BYTES].* };
        return keypair.verify(pubkey, sh.data[SIGNATURE_BYTES..], sig);
    }
};

// ── FEC set reconstruction ───────────────────────────────────────────────────

/// Simple tracker for a FEC set (one leader block segment).
pub const FecSet = struct {
    slot:         types.Slot,
    fec_index:    u32,
    data_shreds:  std.AutoHashMap(u32, Shred),
    coding_shreds: std.AutoHashMap(u32, Shred),
    allocator:    std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, slot: types.Slot, fec_index: u32) FecSet {
        return .{
            .slot          = slot,
            .fec_index     = fec_index,
            .data_shreds   = std.AutoHashMap(u32, Shred).init(allocator),
            .coding_shreds = std.AutoHashMap(u32, Shred).init(allocator),
            .allocator     = allocator,
        };
    }

    pub fn deinit(self: *FecSet) void {
        self.data_shreds.deinit();
        self.coding_shreds.deinit();
    }

    pub fn addShred(self: *FecSet, sh: Shred) !void {
        switch (sh.kind()) {
            .data   => try self.data_shreds.put(sh.index(), sh),
            .coding => try self.coding_shreds.put(sh.index(), sh),
            .unknown => {},
        }
    }

    pub fn isComplete(self: *const FecSet, expected_data: u32) bool {
        return self.data_shreds.count() >= expected_data;
    }

    /// Reassemble raw block data from ordered data shreds.
    pub fn reassemble(self: *const FecSet, out: *std.array_list.Managed(u8)) !void {
        var idx: u32 = 0;
        while (self.data_shreds.get(idx)) |sh| : (idx += 1) {
            const pl = sh.payload();
            const dh = DataHeader.deserialize(
                sh.data[CommonHeader.SIZE..][0..DataHeader.SIZE],
            );
            const real_size = @min(@as(usize, dh.size) -
                (SHRED_DATA_OFFSET + DataHeader.SIZE), DATA_PAYLOAD_SIZE);
            try out.appendSlice(pl[0..real_size]);
            if (sh.isLastInSlot()) break;
        }
    }
};

test "shred data kind detection" {
    var sh: Shred = .{ .data = [_]u8{0} ** SHRED_SIZE };
    sh.data[64] = @intFromEnum(ShredVariant.merkle_data);
    try std.testing.expectEqual(Shred.Kind.data, sh.kind());
}

test "shred factory produces correct number of shreds" {
    const kp = keypair.KeyPair.generate();
    var factory = ShredFactory.init(kp, 42, 1);
    const data = "hello solana blockchain" ** 100;
    const shreds = try factory.shredData(data, 41, std.testing.allocator);
    defer std.testing.allocator.free(shreds);

    try std.testing.expect(shreds.len > 0);
    for (shreds) |sh| {
        try std.testing.expectEqual(@as(u64, 42), sh.slot());
    }
    try std.testing.expect(shreds[shreds.len - 1].isLastInSlot());
}
