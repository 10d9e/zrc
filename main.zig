// Reed-Solomon erasure codec
// Systematic (k,n) RS over GF(2^8) — any k of n shards recover the file.
//
// Usage:
//   rs encode <file|-> [--data K] [--parity M] [--out DIR]
//   rs decode <output> <shard…|->   (- = k concatenated shard blobs on stdin)
//   rs info   <shard> [shard …]

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// ============================================================================
// GF(2^8) — primitive polynomial x^8+x^4+x^3+x^2+1  (0x11D)
// ============================================================================

const GF_POLY: u16 = 0x11D;

// Tables are filled once by gfInit() before any codec work.
var gf_log: [256]u8 = [_]u8{0} ** 256;
var gf_exp: [512]u8 = [_]u8{0} ** 512; // doubled so log sums need no mod
/// gf_mul_lut[c][x] = gfMul(c, x) — speeds hot XOR–multiply chains vs log/exp each byte.
var gf_mul_lut: [256][256]u8 = undefined;

fn gfInit() void {
    var x: u16 = 1;
    for (0..255) |i| {
        gf_exp[i] = @intCast(x);
        gf_exp[i + 255] = @intCast(x); // mirror so gf_exp[a+b] works for a,b<255
        gf_log[@intCast(x)] = @intCast(i);
        x <<= 1;
        if (x >= 256) x ^= GF_POLY;
    }
    gf_exp[510] = gf_exp[0]; // safety sentinel
    // gf_log[0] is left as 0; callers must guard against zero inputs.

    for (0..256) |ci| {
        const c: u8 = @truncate(ci);
        for (0..256) |xi| {
            const xv: u8 = @truncate(xi);
            gf_mul_lut[c][xv] = gfMul(c, xv);
        }
    }
}

inline fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return gf_exp[@as(usize, gf_log[a]) + @as(usize, gf_log[b])];
}

inline fn gfInv(a: u8) u8 {
    std.debug.assert(a != 0);
    return gf_exp[255 - @as(usize, gf_log[a])];
}

/// dst[i] ^= src[i]; vectorized XOR on wide chunks, tail scalar.
fn xorSlice(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len);
    const len = dst.len;
    var i: usize = 0;

    const Vec = @Vector(64, u8);
    const vec_bytes = @sizeOf(Vec);
    while (i + vec_bytes <= len) : (i += vec_bytes) {
        const s = src[i..][0..vec_bytes];
        const d = dst[i..][0..vec_bytes];
        const vs: Vec = @bitCast(s.*);
        const vd: Vec = @bitCast(d.*);
        d.* = @bitCast(vd ^ vs);
    }
    while (i + 8 <= len) : (i += 8) {
        const xi = std.mem.readInt(u64, src[i..][0..8], .little);
        const yi = std.mem.readInt(u64, dst[i..][0..8], .little);
        std.mem.writeInt(u64, dst[i..][0..8], xi ^ yi, .little);
    }
    while (i < len) : (i += 1) dst[i] ^= src[i];
}

/// dst[i] ^= gfMul(c, src[i]); uses multiply LUT; c==1 uses xorSlice.
fn gfXorMulConstSlice(dst: []u8, src: []const u8, c: u8) void {
    if (c == 0) return;
    if (c == 1) {
        xorSlice(dst, src);
        return;
    }
    const lut: *const [256]u8 = &gf_mul_lut[c];
    var idx: usize = 0;
    while (idx < dst.len) : (idx += 1) {
        dst[idx] ^= lut[src[idx]];
    }
}

fn partitionRange(len: usize, parts: usize, index: usize) struct { a: usize, b: usize } {
    std.debug.assert(parts > 0);
    std.debug.assert(index < parts);
    const base = len / parts;
    const rem = len % parts;
    const a = index * base + @min(index, rem);
    const b = a + base + @as(usize, if (index < rem) 1 else 0);
    return .{ .a = a, .b = b };
}

// ============================================================================
// Dense matrix over GF(2^8)
// ============================================================================

const Matrix = struct {
    rows: usize,
    cols: usize,
    buf: []u8,
    alloc: Allocator,

    fn create(alloc: Allocator, rows: usize, cols: usize) !Matrix {
        const buf = try alloc.alloc(u8, rows * cols);
        @memset(buf, 0);
        return .{ .rows = rows, .cols = cols, .buf = buf, .alloc = alloc };
    }

    fn destroy(self: *Matrix) void {
        self.alloc.free(self.buf);
    }

    inline fn get(self: *const Matrix, r: usize, c: usize) u8 {
        return self.buf[r * self.cols + c];
    }

    inline fn put(self: *Matrix, r: usize, c: usize, v: u8) void {
        self.buf[r * self.cols + c] = v;
    }

    fn swapRows(self: *Matrix, r1: usize, r2: usize) void {
        if (r1 == r2) return;
        for (0..self.cols) |j| {
            const tmp = self.get(r1, j);
            self.put(r1, j, self.get(r2, j));
            self.put(r2, j, tmp);
        }
    }

    /// Gauss-Jordan inversion over GF(2^8).
    fn invert(self: *const Matrix, alloc: Allocator) !Matrix {
        const n = self.rows;
        std.debug.assert(n == self.cols);

        // Augmented matrix [self | I_n]
        var aug = try Matrix.create(alloc, n, n * 2);
        defer aug.destroy();
        for (0..n) |i| {
            for (0..n) |j| aug.put(i, j, self.get(i, j));
            aug.put(i, i + n, 1);
        }

        for (0..n) |col| {
            // Find a non-zero pivot in this column at or below diagonal
            var p = col;
            while (p < n and aug.get(p, col) == 0) p += 1;
            if (p == n) return error.SingularMatrix;
            aug.swapRows(col, p);

            // Scale the pivot row so the pivot becomes 1
            const scale = gfInv(aug.get(col, col));
            for (0..n * 2) |j| aug.put(col, j, gfMul(aug.get(col, j), scale));

            // Eliminate this column from every other row
            for (0..n) |row| {
                if (row == col) continue;
                const f = aug.get(row, col);
                if (f == 0) continue;
                for (0..n * 2) |j| {
                    aug.put(row, j, aug.get(row, j) ^ gfMul(f, aug.get(col, j)));
                }
            }
        }

        // Right half of the augmented matrix is now the inverse
        var inv = try Matrix.create(alloc, n, n);
        for (0..n) |i| for (0..n) |j| inv.put(i, j, aug.get(i, j + n));
        return inv;
    }

    /// Matrix product over GF(2^8).
    fn mul(self: *const Matrix, other: *const Matrix, alloc: Allocator) !Matrix {
        std.debug.assert(self.cols == other.rows);
        var res = try Matrix.create(alloc, self.rows, other.cols);
        for (0..self.rows) |i| {
            for (0..other.cols) |j| {
                var s: u8 = 0;
                for (0..self.cols) |kk| s ^= gfMul(self.get(i, kk), other.get(kk, j));
                res.put(i, j, s);
            }
        }
        return res;
    }

};

// ============================================================================
// Reed-Solomon codec
// ============================================================================
//
// We build a systematic (n, k) code using a Vandermonde matrix:
//
//   V[i][j] = (α^i)^j   where α = gf_exp[1] = 2
//
// The encoding matrix E = V × V_top^{-1} where V_top is the top-k rows of V.
// This makes the first k rows of E equal to I_k (systematic property):
// data shards pass through unchanged, parity shards are linear combinations.
//
// Decoding: pick any k available shard indices → sub-matrix of E → invert →
// multiply against received data to recover original k data shards.
//
// Any k rows of a Vandermonde matrix over a field with distinct evaluation
// points form an invertible sub-matrix, so any k-of-n subset works.

const EncodeParityCtx = struct {
    rs: *const RS,
    data: []const []const u8,
    out: [][]u8,
    row_begin: usize,
    row_end: usize,
};

fn encodeParityThread(ctx: EncodeParityCtx) void {
    var i = ctx.row_begin;
    while (i < ctx.row_end) : (i += 1) {
        @memset(ctx.out[i], 0);
        for (0..ctx.rs.k) |j| {
            const c = ctx.rs.enc.get(i, j);
            if (c == 0) continue;
            gfXorMulConstSlice(ctx.out[i], ctx.data[j], c);
        }
    }
}

const RS = struct {
    k: usize,   // data shards
    m: usize,   // parity shards
    n: usize,   // k + m total shards
    enc: Matrix, // (n × k) systematic encoding matrix
    alloc: Allocator,

    fn init(alloc: Allocator, k: usize, m: usize) !RS {
        const n = k + m;
        if (n > 255) return error.TooManyShards;   // GF(2^8) has 255 nonzero elements
        if (k == 0 or m == 0) return error.InvalidParams;

        // Vandermonde matrix V (n × k), evaluation points α^0, α^1, …, α^(n-1)
        var vand = try Matrix.create(alloc, n, k);
        defer vand.destroy();
        for (0..n) |i| {
            const pt: u8 = gf_exp[i]; // distinct nonzero elements of GF(2^8)
            vand.put(i, 0, 1);
            for (1..k) |j| vand.put(i, j, gfMul(vand.get(i, j - 1), pt));
        }

        // Top-k rows form a square Vandermonde; invert it
        var top = try Matrix.create(alloc, k, k);
        defer top.destroy();
        for (0..k) |i| for (0..k) |j| top.put(i, j, vand.get(i, j));

        var top_inv = try top.invert(alloc);
        defer top_inv.destroy();

        // E = V × top^{-1} — first k rows become identity
        const enc = try vand.mul(&top_inv, alloc);
        return .{ .k = k, .m = m, .n = n, .enc = enc, .alloc = alloc };
    }

    fn deinit(self: *RS) void {
        self.enc.destroy();
    }

    /// Encode k data shards into n shards.
    /// `data[0..k]` and `out[0..n]` are equal-length byte slices.
    fn encode(self: *const RS, data: []const []const u8, out: [][]u8) !void {
        for (0..self.k) |i| @memcpy(out[i], data[i]);
        const parity_rows = self.m;
        if (parity_rows == 0) return;
        if (builtin.single_threaded or parity_rows < 2) {
            encodeParityThread(.{ .rs = self, .data = data, .out = out, .row_begin = self.k, .row_end = self.n });
            return;
        }
        const cpu = std.Thread.getCpuCount() catch 1;
        const n_threads = @min(cpu, parity_rows);
        if (n_threads <= 1) {
            encodeParityThread(.{ .rs = self, .data = data, .out = out, .row_begin = self.k, .row_end = self.n });
            return;
        }
        const threads = try self.alloc.alloc(std.Thread, n_threads);
        defer self.alloc.free(threads);
        var t: usize = 0;
        while (t < n_threads) : (t += 1) {
            const pr = partitionRange(parity_rows, n_threads, t);
            const row_begin = self.k + pr.a;
            const row_end = self.k + pr.b;
            threads[t] = try std.Thread.spawn(.{}, encodeParityThread, .{@as(EncodeParityCtx, .{
                .rs = self,
                .data = data,
                .out = out,
                .row_begin = row_begin,
                .row_end = row_end,
            })});
        }
        for (threads) |th| th.join();
    }

    /// Recover k original data shards from exactly k (index, shard) pairs.
    /// `indices[i]` is the position of `shards[i]` in the full n-shard set.
    fn decode(
        self: *const RS,
        alloc: Allocator,
        indices: []const usize,
        shards: []const []const u8,
        out: [][]u8,
    ) !void {
        std.debug.assert(indices.len == self.k);

        // Build the k×k sub-matrix by picking the rows at `indices`
        var sub = try Matrix.create(alloc, self.k, self.k);
        defer sub.destroy();
        for (0..self.k) |i| {
            for (0..self.k) |j| sub.put(i, j, self.enc.get(indices[i], j));
        }

        // Invert it — then `data = sub_inv × received`
        var sub_inv = try sub.invert(alloc);
        defer sub_inv.destroy();

        const k_rows = self.k;
        if (builtin.single_threaded or k_rows < 2) {
            decodeRecoverThread(.{
                .sub_inv = &sub_inv,
                .shards = shards,
                .out = out,
                .k = k_rows,
                .row_begin = 0,
                .row_end = k_rows,
            });
        } else {
            const cpu = std.Thread.getCpuCount() catch 1;
            const n_threads = @min(cpu, k_rows);
            if (n_threads <= 1) {
                decodeRecoverThread(.{
                    .sub_inv = &sub_inv,
                    .shards = shards,
                    .out = out,
                    .k = k_rows,
                    .row_begin = 0,
                    .row_end = k_rows,
                });
            } else {
                const threads = try self.alloc.alloc(std.Thread, n_threads);
                defer self.alloc.free(threads);
                var t: usize = 0;
                while (t < n_threads) : (t += 1) {
                    const pr = partitionRange(k_rows, n_threads, t);
                    threads[t] = try std.Thread.spawn(.{}, decodeRecoverThread, .{@as(DecodeRecoverCtx, .{
                        .sub_inv = &sub_inv,
                        .shards = shards,
                        .out = out,
                        .k = k_rows,
                        .row_begin = pr.a,
                        .row_end = pr.b,
                    })});
                }
                for (threads) |th| th.join();
            }
        }
    }
};

const DecodeRecoverCtx = struct {
    sub_inv: *const Matrix,
    shards: []const []const u8,
    out: [][]u8,
    k: usize,
    row_begin: usize,
    row_end: usize,
};

fn decodeRecoverThread(ctx: DecodeRecoverCtx) void {
    var i = ctx.row_begin;
    while (i < ctx.row_end) : (i += 1) {
        @memset(ctx.out[i], 0);
        for (0..ctx.k) |j| {
            const c = ctx.sub_inv.get(i, j);
            if (c == 0) continue;
            gfXorMulConstSlice(ctx.out[i], ctx.shards[j], c);
        }
    }
}

const ParityStripeCtx = struct {
    rs: *const RS,
    col: [][]u8,
    out_par: [][]u8,
    off_a: usize,
    off_b: usize,
    k: usize,
    m: usize,
};

fn parityStripeOffRange(ctx: ParityStripeCtx) void {
    const kk = ctx.k;
    const mm = ctx.m;
    for (ctx.off_a..ctx.off_b) |off| {
        var tt: usize = 0;
        while (tt < mm) : (tt += 1) {
            const pi = kk + tt;
            var acc: u8 = 0;
            var jj: usize = 0;
            while (jj < kk) : (jj += 1) {
                const c = ctx.rs.enc.get(pi, jj);
                if (c != 0) acc ^= gf_mul_lut[c][ctx.col[jj][off]];
            }
            ctx.out_par[tt][off] = acc;
        }
    }
}

// ============================================================================
// Shard file format
//
//  Offset  Len  Field
//  ------  ---  -----
//       0    4  magic  "RS\x01\x00"
//       4    1  k      data-shard count
//       5    1  m      parity-shard count
//       6    1  index  this shard's 0-based index
//       7    1  (padding / reserved)
//       8    8  file_size  original file length, u64 little-endian
//      16    N  shard_data
// ============================================================================

const MAGIC = [4]u8{ 'R', 'S', 0x01, 0x00 };

const ShardHeader = struct {
    k: u8,
    m: u8,
    index: u8,
    file_size: u64,
};

fn writeShardHeader(w: anytype, hdr: ShardHeader) !void {
    try w.writeAll(&MAGIC);
    try w.writeByte(hdr.k);
    try w.writeByte(hdr.m);
    try w.writeByte(hdr.index);
    try w.writeByte(0); // reserved
    try w.writeInt(u64, hdr.file_size, .little);
}

fn writeShardFile(path: []const u8, hdr: ShardHeader, data: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    const w = f.deprecatedWriter();
    try writeShardHeader(&w, hdr);
    try w.writeAll(data);
}

/// Larger inputs use two-pass streaming (no full-file RAM). Smaller files stay in memory for speed.
const max_encode_memory: usize = 1 << 30;
const stream_chunk: usize = 64 * 1024;

fn copyFileBytes(out: std.fs.File, buf: []u8, mut_in: *std.fs.File, count: u64) !void {
    var left = count;
    while (left > 0) {
        const n: usize = @intCast(@min(left, buf.len));
        const got = try mut_in.readAll(buf[0..n]);
        if (got != n) return error.UnexpectedEndOfFile;
        try out.writeAll(buf[0..n]);
        left -= n;
    }
}

fn writeZeroPad(out: std.fs.File, len: usize, buf: []u8) !void {
    @memset(buf, 0);
    var left = len;
    while (left > 0) {
        const n = @min(left, buf.len);
        try out.writeAll(buf[0..n]);
        left -= n;
    }
}

/// Pass 1: split input into k data shard files (with headers). Pass 2: derive parity shards.
fn encodeStreaming(
    alloc: Allocator,
    in: *std.fs.File,
    file_size: u64,
    k: usize,
    m: usize,
    out_dir: []const u8,
    base: []const u8,
    stdout: *std.Io.Writer,
) !void {
    const n = k + m;
    const shard_sz: usize = @intCast((file_size + @as(u64, @intCast(k)) - 1) / @as(u64, @intCast(k)));
    const shard_sz_u64: u64 = @intCast(shard_sz);

    gfInit();
    var rs = try RS.init(alloc, k, m);
    defer rs.deinit();

    var path_buf: [1024]u8 = undefined;

    // --- Pass 1: data shards ---
    var data_files: [255]std.fs.File = undefined;
    defer for (0..k) |j| data_files[j].close();

    for (0..k) |j| {
        const shard_path = try std.fmt.bufPrint(
            &path_buf, "{s}/{s}.shard{d:0>3}", .{ out_dir, base, j });
        data_files[j] = try std.fs.cwd().createFile(shard_path, .{});
        const hdr = ShardHeader{
            .k = @intCast(k),
            .m = @intCast(m),
            .index = @intCast(j),
            .file_size = file_size,
        };
        const w = data_files[j].deprecatedWriter();
        try writeShardHeader(&w, hdr);
    }

    const copy_buf = try alloc.alloc(u8, stream_chunk);
    defer alloc.free(copy_buf);

    var j: usize = 0;
    while (j < k) : (j += 1) {
        const base_off: u64 = @as(u64, @intCast(j)) * shard_sz_u64;
        if (base_off >= file_size) {
            try writeZeroPad(data_files[j], shard_sz, copy_buf);
            continue;
        }
        const take: u64 = @min(shard_sz_u64, file_size - base_off);
        try in.seekTo(base_off);
        try copyFileBytes(data_files[j], copy_buf, in, take);
        if (take < shard_sz_u64) {
            try writeZeroPad(data_files[j], @intCast(shard_sz_u64 - take), copy_buf);
        }
    }

    // `createFile` may be write-only; pass 2 must read data shards — reopen for reading.
    for (0..k) |jj| {
        data_files[jj].close();
        const shard_path = try std.fmt.bufPrint(
            &path_buf, "{s}/{s}.shard{d:0>3}", .{ out_dir, base, jj });
        data_files[jj] = try std.fs.cwd().openFile(shard_path, .{});
    }

    // --- Pass 2: parity shards (column chunks) ---
    var parity_files: [255]std.fs.File = undefined;
    defer for (0..m) |t| parity_files[t].close();

    for (0..m) |t| {
        const pi = k + t;
        const shard_path = try std.fmt.bufPrint(
            &path_buf, "{s}/{s}.shard{d:0>3}", .{ out_dir, base, pi });
        parity_files[t] = try std.fs.cwd().createFile(shard_path, .{});
        const hdr = ShardHeader{
            .k = @intCast(k),
            .m = @intCast(m),
            .index = @intCast(pi),
            .file_size = file_size,
        };
        const w = parity_files[t].deprecatedWriter();
        try writeShardHeader(&w, hdr);
    }

    var col = try alloc.alloc([]u8, k);
    for (0..k) |jj| {
        col[jj] = try alloc.alloc(u8, stream_chunk);
    }
    defer {
        for (col) |sl| alloc.free(sl);
        alloc.free(col);
    }

    var out_par = try alloc.alloc([]u8, m);
    for (0..m) |tt| {
        out_par[tt] = try alloc.alloc(u8, stream_chunk);
    }
    defer {
        for (out_par) |sl| alloc.free(sl);
        alloc.free(out_par);
    }

    var p: usize = 0;
    while (p < shard_sz) {
        const csize: usize = @min(stream_chunk, shard_sz - p);
        for (0..k) |jj| {
            try data_files[jj].seekTo(16 + @as(u64, @intCast(p)));
            _ = try data_files[jj].readAll(col[jj][0..csize]);
        }
        const min_off_chunk: usize = 4096;
        if (builtin.single_threaded or csize < min_off_chunk * 2) {
            parityStripeOffRange(.{
                .rs = &rs,
                .col = col,
                .out_par = out_par,
                .off_a = 0,
                .off_b = csize,
                .k = k,
                .m = m,
            });
        } else {
            const cpu = std.Thread.getCpuCount() catch 1;
            const n_threads = @min(cpu, @max(1, csize / min_off_chunk));
            if (n_threads <= 1) {
                parityStripeOffRange(.{
                    .rs = &rs,
                    .col = col,
                    .out_par = out_par,
                    .off_a = 0,
                    .off_b = csize,
                    .k = k,
                    .m = m,
                });
            } else {
                const threads = try alloc.alloc(std.Thread, n_threads);
                defer alloc.free(threads);
                var t: usize = 0;
                while (t < n_threads) : (t += 1) {
                    const pr = partitionRange(csize, n_threads, t);
                    threads[t] = try std.Thread.spawn(.{}, parityStripeOffRange, .{@as(ParityStripeCtx, .{
                        .rs = &rs,
                        .col = col,
                        .out_par = out_par,
                        .off_a = pr.a,
                        .off_b = pr.b,
                        .k = k,
                        .m = m,
                    })});
                }
                for (threads) |th| th.join();
            }
        }
        for (0..m) |tt| {
            try parity_files[tt].writeAll(out_par[tt][0..csize]);
        }
        p += csize;
    }

    try stdout.print("\n", .{});
    for (0..n) |si| {
        const shard_path = try std.fmt.bufPrint(
            &path_buf, "{s}/{s}.shard{d:0>3}", .{ out_dir, base, si });
        const kind = if (si < k) "data  " else "parity";
        try stdout.print("  [{s}] {s}\n", .{ kind, shard_path });
    }

    var sz_buf1: [32]u8 = undefined;
    var sz_buf2: [32]u8 = undefined;
    try stdout.print(
        \\
        \\  Source   : {s}  ({s})
        \\  Shards   : {d} total ({d} data + {d} parity), {s} each
        \\  Recovery : any {d} of {d} shards reconstruct the file
        \\
    , .{
        base,
        fmtSize(&sz_buf1, file_size),
        n, k, m,
        fmtSize(&sz_buf2, shard_sz),
        k, n,
    });
}

fn spoolStdinToPath(path: []const u8) !void {
    const out = try std.fs.cwd().createFile(path, .{});
    defer out.close();
    const stdin = std.fs.File.stdin();
    var buf: [8 * 1024 * 1024]u8 = undefined;
    while (true) {
        const n = try stdin.read(&buf);
        if (n == 0) break;
        try out.writeAll(buf[0..n]);
    }
}

const ShardFile = struct {
    hdr: ShardHeader,
    data: []u8,
    alloc: Allocator,

    fn deinit(self: *ShardFile) void {
        self.alloc.free(self.data);
    }
};

fn readShardFromReader(alloc: Allocator, r: anytype) !ShardFile {
    var magic: [4]u8 = undefined;
    try r.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, &MAGIC)) return error.InvalidMagic;

    const kb = try r.readByte();
    const mb = try r.readByte();
    const index = try r.readByte();
    _ = try r.readByte(); // reserved
    const fsz = try r.readInt(u64, .little);

    const kk: usize = @intCast(kb);
    if (kk == 0) return error.InvalidParams;
    const shard_sz: usize = @intCast((fsz + @as(u64, @intCast(kk)) - 1) / @as(u64, @intCast(kk)));

    const data = try alloc.alloc(u8, shard_sz);
    errdefer alloc.free(data);
    try r.readNoEof(data);

    return ShardFile{
        .hdr = .{ .k = kb, .m = mb, .index = index, .file_size = fsz },
        .data = data,
        .alloc = alloc,
    };
}

fn readShardFile(alloc: Allocator, path: []const u8) !ShardFile {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var r = f.deprecatedReader();
    return readShardFromReader(alloc, &r);
}

// ============================================================================
// Helpers
// ============================================================================

fn fmtSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes < 1024)
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch buf[0..0];
    if (bytes < 1024 * 1024)
        return std.fmt.bufPrint(buf, "{d:.1} KiB", .{@as(f64, @floatFromInt(bytes)) / 1024.0}) catch buf[0..0];
    if (bytes < 1024 * 1024 * 1024)
        return std.fmt.bufPrint(buf, "{d:.2} MiB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d:.2} GiB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)}) catch buf[0..0];
}

// ============================================================================
// encode command
// ============================================================================

fn cmdEncode(alloc: Allocator, argv: []const []const u8) !void {
    var stderr = std.fs.File.stderr().writer(&.{});
    var stdout_file = std.fs.File.stdout().writer(&.{});
    var stdout: *std.Io.Writer = &stdout_file.interface;

    if (argv.len == 0) {
        try stderr.interface.print(
            "Usage: rs encode <file|-> [--data K] [--parity M] [--out DIR]\n   (- reads stdin; spools then encodes; >1GiB files use streaming)\n", .{});
        return error.InvalidArgs;
    }

    const src_path = argv[0];
    var k: usize = 6;
    var m: usize = 4;
    var out_dir: []const u8 = ".";

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--data") or std.mem.eql(u8, a, "-k")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.interface.print("Missing value for {s}\n", .{a});
                return error.InvalidArgs;
            }
            k = std.fmt.parseInt(usize, argv[i], 10) catch {
                try stderr.interface.print("Bad integer for {s}: '{s}'\n", .{ a, argv[i] });
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, a, "--parity") or std.mem.eql(u8, a, "-m")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.interface.print("Missing value for {s}\n", .{a});
                return error.InvalidArgs;
            }
            m = std.fmt.parseInt(usize, argv[i], 10) catch {
                try stderr.interface.print("Bad integer for {s}: '{s}'\n", .{ a, argv[i] });
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, a, "--out") or std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.interface.print("Missing value for {s}\n", .{a});
                return error.InvalidArgs;
            }
            out_dir = argv[i];
        } else {
            try stderr.interface.print("Unknown option: '{s}'\n", .{a});
            return error.InvalidArgs;
        }
    }

    if (k < 1 or m < 1 or k + m > 255) {
        try stderr.interface.print(
            "Invalid: k={d}, m={d} — need k≥1, m≥1, k+m≤255\n", .{ k, m });
        return error.InvalidArgs;
    }

    try std.fs.cwd().makePath(out_dir);

    var stdin_tmp: ?[]u8 = null;
    defer if (stdin_tmp) |p| {
        std.fs.cwd().deleteFile(p) catch {};
        alloc.free(p);
    };

    var input_path: []const u8 = src_path;
    if (std.mem.eql(u8, src_path, "-")) {
        const tmp = try std.fmt.allocPrint(alloc, "{s}/.rs-encode-{x}.tmp", .{ out_dir, std.time.nanoTimestamp() });
        stdin_tmp = tmp;
        spoolStdinToPath(tmp) catch |err| {
            try stderr.interface.print("Cannot spool stdin: {}\n", .{err});
            return err;
        };
        input_path = tmp;
    }

    var in_file = std.fs.cwd().openFile(input_path, .{}) catch |err| {
        try stderr.interface.print("Cannot open '{s}': {}\n", .{ input_path, err });
        return err;
    };
    defer in_file.close();

    const file_size = try in_file.getEndPos();
    if (file_size == 0) {
        try stderr.interface.print("Input is empty.\n", .{});
        return error.EmptyInput;
    }

    const base = if (std.mem.eql(u8, src_path, "-")) "stdin" else std.fs.path.basename(src_path);
    const label = if (std.mem.eql(u8, src_path, "-")) "-" else src_path;

    if (file_size > max_encode_memory) {
        try in_file.seekTo(0);
        try encodeStreaming(alloc, &in_file, file_size, k, m, out_dir, base, stdout);
        return;
    }

    try in_file.seekTo(0);
    const raw = try in_file.readToEndAlloc(alloc, max_encode_memory);
    defer alloc.free(raw);
    if (raw.len != file_size) {
        try stderr.interface.print("Short read (expected {d} bytes, got {d}).\n", .{ file_size, raw.len });
        return error.UnexpectedEndOfFile;
    }

    const file_size_usize: usize = @intCast(file_size);
    const shard_sz = (file_size_usize + k - 1) / k;
    const padded_sz = shard_sz * k;

    var padded = try alloc.alloc(u8, padded_sz);
    defer alloc.free(padded);
    @memcpy(padded[0..file_size_usize], raw);
    if (file_size_usize < padded_sz) @memset(padded[file_size_usize..], 0);

    var data_views = try alloc.alloc([]const u8, k);
    defer alloc.free(data_views);
    for (0..k) |si| data_views[si] = padded[si * shard_sz .. (si + 1) * shard_sz];

    const n = k + m;
    var out_bufs = try alloc.alloc([]u8, n);
    defer alloc.free(out_bufs);
    for (0..n) |si| out_bufs[si] = try alloc.alloc(u8, shard_sz);
    defer for (out_bufs) |sb| alloc.free(sb);

    gfInit();
    var rs = try RS.init(alloc, k, m);
    defer rs.deinit();
    try rs.encode(data_views, out_bufs);

    var path_buf: [1024]u8 = undefined;
    try stdout.print("\n", .{});
    for (0..n) |si| {
        const shard_path = try std.fmt.bufPrint(
            &path_buf, "{s}/{s}.shard{d:0>3}", .{ out_dir, base, si });
        const hdr = ShardHeader{
            .k         = @intCast(k),
            .m         = @intCast(m),
            .index     = @intCast(si),
            .file_size = file_size,
        };
        try writeShardFile(shard_path, hdr, out_bufs[si]);
        const kind = if (si < k) "data  " else "parity";
        try stdout.print("  [{s}] {s}\n", .{ kind, shard_path });
    }

    var sz_buf1: [32]u8 = undefined;
    var sz_buf2: [32]u8 = undefined;
    try stdout.print(
        \\
        \\  Source   : {s}  ({s})
        \\  Shards   : {d} total ({d} data + {d} parity), {s} each
        \\  Recovery : any {d} of {d} shards reconstruct the file
        \\
    , .{
        label,
        fmtSize(&sz_buf1, file_size),
        n, k, m,
        fmtSize(&sz_buf2, shard_sz),
        k, n,
    });
}

// ============================================================================
// decode command
// ============================================================================

fn cmdDecode(alloc: Allocator, argv: []const []const u8) !void {
    var stderr = std.fs.File.stderr().writer(&.{});
    var stdout = std.fs.File.stdout().writer(&.{});

    if (argv.len < 2) {
        try stderr.interface.print(
            "Usage: rs decode <output_file> <shard|-> [shard …]\n" ++
                "  Last arg may be paths to k shards, or a lone '-' to read k\n" ++
                "  concatenated shard files from stdin (any order; each has a header).\n", .{});
        return error.InvalidArgs;
    }

    const dst_path = argv[0];

    var shards: []ShardFile = undefined;
    var n_read: usize = 0;
    defer {
        if (n_read > 0) {
            for (shards[0..n_read]) |*s| s.deinit();
            alloc.free(shards);
        }
    }

    if (argv.len == 2 and std.mem.eql(u8, argv[1], "-")) {
        var stdin_reader = std.fs.File.stdin().deprecatedReader();
        const first = readShardFromReader(alloc, &stdin_reader) catch |err| {
            try stderr.interface.print("Cannot read shards from stdin: {}\n", .{err});
            return err;
        };
        const k0: usize = @intCast(first.hdr.k);
        shards = try alloc.alloc(ShardFile, k0);
        shards[0] = first;
        n_read = 1;
        var ii: usize = 1;
        while (ii < k0) : (ii += 1) {
            shards[ii] = readShardFromReader(alloc, &stdin_reader) catch |err| {
                try stderr.interface.print("Cannot read shard {d} from stdin: {}\n", .{ ii, err });
                return err;
            };
            n_read = ii + 1;
        }
    } else {
        const shard_paths = argv[1..];
        shards = try alloc.alloc(ShardFile, shard_paths.len);
        n_read = 0;
        for (shard_paths) |p| {
            shards[n_read] = readShardFile(alloc, p) catch |err| {
                try stderr.interface.print("Cannot read shard '{s}': {}\n", .{ p, err });
                return err;
            };
            n_read += 1;
        }
    }

    // ── Validate compatibility ────────────────────────────────────────────────
    const h0 = shards[0].hdr;
    const k: usize = h0.k;
    const m: usize = h0.m;
    const file_size: usize = @intCast(h0.file_size);

    for (shards[1..n_read], 1..) |s, idx| {
        if (s.hdr.k != h0.k or s.hdr.m != h0.m) {
            try stderr.interface.print(
                "Shard #{d} has different k/m params than shard #0.\n", .{idx});
            return error.ShardMismatch;
        }
        if (s.hdr.file_size != h0.file_size) {
            try stderr.interface.print(
                "Shard #{d} reports a different original file size.\n", .{idx});
            return error.ShardMismatch;
        }
    }

    if (n_read < k) {
        try stderr.interface.print(
            "Need at least {d} shards; only {d} provided.\n", .{ k, n_read });
        return error.NotEnoughShards;
    }

    const shard_sz = shards[0].data.len;
    for (shards[1..k]) |s| {
        if (s.data.len != shard_sz) {
            try stderr.interface.print("Shard data-length mismatch.\n", .{});
            return error.ShardMismatch;
        }
    }

    // Check for duplicate indices
    for (0..k) |a| {
        for (a + 1..k) |b| {
            if (shards[a].hdr.index == shards[b].hdr.index) {
                try stderr.interface.print(
                    "Duplicate shard index {d} at positions {d} and {d}.\n",
                    .{ shards[a].hdr.index, a, b });
                return error.DuplicateShardIndex;
            }
        }
    }

    // ── Decode ───────────────────────────────────────────────────────────────
    var indices = try alloc.alloc(usize, k);
    defer alloc.free(indices);
    var recv = try alloc.alloc([]const u8, k);
    defer alloc.free(recv);
    for (0..k) |i| {
        indices[i] = shards[i].hdr.index;
        recv[i]    = shards[i].data;
    }

    var out_bufs = try alloc.alloc([]u8, k);
    defer alloc.free(out_bufs);
    for (0..k) |i| out_bufs[i] = try alloc.alloc(u8, shard_sz);
    defer for (out_bufs) |sb| alloc.free(sb);

    gfInit();
    var rs = try RS.init(alloc, k, m);
    defer rs.deinit();
    try rs.decode(alloc, indices, recv, out_bufs);

    // ── Reassemble and write ─────────────────────────────────────────────────
    const padded_sz = shard_sz * k;
    var assembled = try alloc.alloc(u8, padded_sz);
    defer alloc.free(assembled);
    for (0..k) |i| @memcpy(assembled[i * shard_sz .. (i + 1) * shard_sz], out_bufs[i]);

    const actual = @min(file_size, padded_sz);
    {
        const f = try std.fs.cwd().createFile(dst_path, .{});
        defer f.close();
        try f.writeAll(assembled[0..actual]);
    }

    var sz_buf: [32]u8 = undefined;
    if (n_read > k) {
        try stdout.interface.print(
            "Note: {d} shards provided; using first {d}.\n", .{ n_read, k });
    }
    try stdout.interface.print("Decoded '{s}' ({s}).\n",
        .{ dst_path, fmtSize(&sz_buf, actual) });
}

// ============================================================================
// info command
// ============================================================================

fn cmdInfo(alloc: Allocator, argv: []const []const u8) !void {
    var stderr = std.fs.File.stderr().writer(&.{});
    var stdout = std.fs.File.stdout().writer(&.{});

    if (argv.len == 0) {
        try stderr.interface.print("Usage: rs info <shard> [shard …]\n", .{});
        return error.InvalidArgs;
    }

    for (argv) |p| {
        var s = readShardFile(alloc, p) catch |err| {
            try stderr.interface.print("Cannot read '{s}': {}\n", .{ p, err });
            continue;
        };
        defer s.deinit();
        const total: usize = @as(usize, s.hdr.k) + @as(usize, s.hdr.m);
        const kind  = if (s.hdr.index < s.hdr.k) "data" else "parity";
        var sb1: [32]u8 = undefined;
        var sb2: [32]u8 = undefined;
        try stdout.interface.print(
            \\{s}
            \\  Shard index : {d} / {d}  ({s})
            \\  Scheme      : ({d},{d}) — any {d} of {d} recover the file
            \\  Shard size  : {s}
            \\  File size   : {s}
            \\
        , .{
            p,
            s.hdr.index, total - 1, kind,
            s.hdr.k, total, s.hdr.k, total,
            fmtSize(&sb1, s.data.len),
            fmtSize(&sb2, s.hdr.file_size),
        });
    }
}

// ============================================================================
// verify command — re-encode from recovered data and compare parity shards
// ============================================================================

fn cmdVerify(alloc: Allocator, argv: []const []const u8) !void {
    var stderr = std.fs.File.stderr().writer(&.{});
    var stdout = std.fs.File.stdout().writer(&.{});

    if (argv.len == 0) {
        try stderr.interface.print(
            "Usage: rs verify <shard0> <shard1> …  (provide ALL n shards)\n", .{});
        return error.InvalidArgs;
    }

    // Read every shard
    var shards = try alloc.alloc(ShardFile, argv.len);
    defer alloc.free(shards);
    var n_read: usize = 0;
    defer for (shards[0..n_read]) |*s| s.deinit();

    for (argv) |p| {
        shards[n_read] = readShardFile(alloc, p) catch |err| {
            try stderr.interface.print("Cannot read '{s}': {}\n", .{ p, err });
            return err;
        };
        n_read += 1;
    }

    const h0    = shards[0].hdr;
    const k: usize = h0.k;
    const m: usize = h0.m;
    const n: usize = k + m;

    if (n_read != n) {
        try stderr.interface.print("verify needs all {d} shards; got {d}.\n", .{ n, n_read });
        return error.WrongShardCount;
    }

    // Sort shards by index
    std.mem.sort(ShardFile, shards[0..n_read], {}, struct {
        fn lt(_: void, a: ShardFile, b: ShardFile) bool {
            return a.hdr.index < b.hdr.index;
        }
    }.lt);

    // Validate all have the same parameters
    for (shards[0..n_read]) |s| {
        if (s.hdr.k != h0.k or s.hdr.m != h0.m or s.hdr.file_size != h0.file_size) {
            try stderr.interface.print("Shard parameter mismatch.\n", .{});
            return error.ShardMismatch;
        }
    }

    // Re-encode from the k data shards
    const shard_sz = shards[0].data.len;
    var data_views = try alloc.alloc([]const u8, k);
    defer alloc.free(data_views);
    for (0..k) |i| data_views[i] = shards[i].data;

    var re_bufs = try alloc.alloc([]u8, n);
    defer alloc.free(re_bufs);
    for (0..n) |i| re_bufs[i] = try alloc.alloc(u8, shard_sz);
    defer for (re_bufs) |rb| alloc.free(rb);

    gfInit();
    var rs = try RS.init(alloc, k, m);
    defer rs.deinit();
    try rs.encode(data_views, re_bufs);

    // Compare parity shards
    var ok = true;
    for (k..n) |i| {
        if (!std.mem.eql(u8, re_bufs[i], shards[i].data)) {
            try stderr.interface.print("FAIL: parity shard {d} does not match.\n", .{i});
            ok = false;
        }
    }
    if (ok) {
        try stdout.interface.print("OK: all {d} parity shards verified.\n", .{m});
    }
}

// ============================================================================
// Help text
// ============================================================================

const HELP =
    \\Reed-Solomon erasure codec — split any file into recoverable shards.
    \\
    \\COMMANDS
    \\  encode <file|-> [options]      Split a file into n shards (- = stdin; >1GiB streams)
    \\  decode <output> <shard…|->     Recover from ≥k shards (see below)
    \\  info   <shard> …               Print shard metadata
    \\  verify <shard> …               Re-encode & compare parity (needs all n)
    \\  help                           Show this help
    \\
    \\ENCODE OPTIONS
    \\  --data   K   Data shards   (default 6; min 1)
    \\  --parity M   Parity shards (default 4; min 1)
    \\  --out    DIR Output directory for shard files (default .)
    \\  k+m must be ≤ 255. Inputs larger than 1 GiB use a disk streaming encoder.
    \\
    \\SHARD FILES
    \\  Named <original_filename>.shard000, .shard001, …
    \\  Any k of the k+m shards are sufficient to recover the original file.
    \\
    \\EXAMPLES
    \\  # Encode with defaults (6-of-10)
    \\  rs encode photo.jpg
    \\
    \\  # Encode with custom params (3-of-5)
    \\  rs encode archive.tar.gz --data 3 --parity 2 --out /mnt/backup
    \\
    \\  # Or pipe exactly k shard files (binary concat): cat a b c | rs decode out -
    \\  # Recover using any 3 shards (indices can be non-contiguous)
    \\  rs decode archive.tar.gz /mnt/backup/archive.tar.gz.shard000 \
    \\                           /mnt/backup/archive.tar.gz.shard002 \
    \\                           /mnt/backup/archive.tar.gz.shard004
    \\
    \\  # Inspect a shard
    \\  rs info /mnt/backup/archive.tar.gz.shard001
    \\
;

// ============================================================================
// Entry point
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stderr = std.fs.File.stderr().writer(&.{});
    var stdout = std.fs.File.stdout().writer(&.{});

    const raw_args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, raw_args);
    const args = raw_args[1..];

    if (args.len == 0) {
        try stdout.interface.print("{s}\n", .{HELP});
        return;
    }

    const cmd  = args[0];
    const rest = if (args.len > 1) args[1..] else args[0..0];

    if (std.mem.eql(u8, cmd, "encode")) {
        cmdEncode(alloc, rest) catch |err| {
            try stderr.interface.print("encode failed: {}\n", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, cmd, "decode")) {
        cmdDecode(alloc, rest) catch |err| {
            try stderr.interface.print("decode failed: {}\n", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, cmd, "info")) {
        cmdInfo(alloc, rest) catch |err| {
            try stderr.interface.print("info failed: {}\n", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, cmd, "verify")) {
        cmdVerify(alloc, rest) catch |err| {
            try stderr.interface.print("verify failed: {}\n", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, cmd, "help") or
               std.mem.eql(u8, cmd, "--help") or
               std.mem.eql(u8, cmd, "-h"))
    {
        try stdout.interface.print("{s}\n", .{HELP});
    } else {
        try stderr.interface.print("Unknown command '{s}'. Run 'rs help' for usage.\n", .{cmd});
        std.process.exit(1);
    }
}

// ============================================================================
// Unit tests
// ============================================================================

test "GF mul commutativity and identity" {
    gfInit();
    try std.testing.expectEqual(@as(u8, 0), gfMul(0, 123));
    try std.testing.expectEqual(@as(u8, 0), gfMul(99, 0));
    try std.testing.expectEqual(@as(u8, 7), gfMul(7, 1));
    try std.testing.expectEqual(@as(u8, 1), gfMul(2, gfInv(2)));
    // a * b == b * a
    try std.testing.expectEqual(gfMul(37, 91), gfMul(91, 37));
    // (a*b)*c == a*(b*c)
    try std.testing.expectEqual(gfMul(gfMul(5, 17), 200), gfMul(5, gfMul(17, 200)));
}

test "GF distributivity" {
    gfInit();
    const a: u8 = 77; const b: u8 = 133; const c: u8 = 200;
    // a*(b XOR c) == a*b XOR a*c
    try std.testing.expectEqual(
        gfMul(a, b ^ c),
        gfMul(a, b) ^ gfMul(a, c));
}

test "matrix invert round-trip" {
    gfInit();
    const alloc = std.testing.allocator;
    // Build identity-like matrix and invert it
    var m = try Matrix.create(alloc, 3, 3);
    defer m.destroy();
    m.put(0,0,1); m.put(0,1,0); m.put(0,2,0);
    m.put(1,0,0); m.put(1,1,2); m.put(1,2,0);
    m.put(2,0,0); m.put(2,1,0); m.put(2,2,4);
    var inv = try m.invert(alloc);
    defer inv.destroy();
    var prod = try m.mul(&inv, alloc);
    defer prod.destroy();
    for (0..3) |i| for (0..3) |j| {
        const expected: u8 = if (i == j) 1 else 0;
        try std.testing.expectEqual(expected, prod.get(i, j));
    };
}

test "RS systematic property" {
    gfInit();
    const alloc = std.testing.allocator;
    const k: usize = 4; const m: usize = 3;
    var rs = try RS.init(alloc, k, m);
    defer rs.deinit();
    // First k rows of enc must equal identity
    for (0..k) |i| {
        for (0..k) |j| {
            const expected: u8 = if (i == j) 1 else 0;
            try std.testing.expectEqual(expected, rs.enc.get(i, j));
        }
    }
}

test "RS encode + decode full round-trip" {
    gfInit();
    const alloc = std.testing.allocator;
    const k: usize = 4; const m: usize = 3; const n = k + m;
    const sz: usize = 64;

    var rs = try RS.init(alloc, k, m);
    defer rs.deinit();

    // Create deterministic data shards
    var data_mem: [k][sz]u8 = undefined;
    for (0..k) |i| for (0..sz) |p| { data_mem[i][p] = @intCast((i * 17 + p * 7) % 251); };
    var data_views: [k][]const u8 = undefined;
    for (0..k) |i| data_views[i] = &data_mem[i];

    // Allocate and encode
    var all_bufs: [n][]u8 = undefined;
    for (0..n) |i| all_bufs[i] = try alloc.alloc(u8, sz);
    defer for (0..n) |i| alloc.free(all_bufs[i]);

    try rs.encode(&data_views, &all_bufs);

    // Decode using shards [0, 2, 5, 6]  (skip 1, 3, 4)
    const test_idx = [_]usize{ 0, 2, 5, 6 };
    var recv: [k][]const u8 = undefined;
    for (0..k) |i| recv[i] = all_bufs[test_idx[i]];

    var out_bufs: [k][]u8 = undefined;
    for (0..k) |i| out_bufs[i] = try alloc.alloc(u8, sz);
    defer for (0..k) |i| alloc.free(out_bufs[i]);

    try rs.decode(alloc, &test_idx, &recv, &out_bufs);

    for (0..k) |i| {
        try std.testing.expectEqualSlices(u8, &data_mem[i], out_bufs[i]);
    }
}

test "RS single-byte file" {
    gfInit();
    const alloc = std.testing.allocator;
    const k: usize = 3; const m: usize = 2; const n = k + m;
    var rs = try RS.init(alloc, k, m);
    defer rs.deinit();

    // 1-byte shards (file of 3 bytes, one per data shard)
    var d: [k][1]u8 = .{ .{0xDE}, .{0xAD}, .{0xBE} };
    var dv: [k][]const u8 = undefined;
    for (0..k) |i| dv[i] = &d[i];

    var all: [n][]u8 = undefined;
    for (0..n) |i| all[i] = try alloc.alloc(u8, 1);
    defer for (0..n) |i| alloc.free(all[i]);
    try rs.encode(&dv, &all);

    // Recover using only parity shards [3, 4] + data shard [1]
    const idx = [_]usize{ 1, 3, 4 };
    var recv: [k][]const u8 = .{ all[1], all[3], all[4] };
    var out: [k][]u8 = undefined;
    for (0..k) |i| out[i] = try alloc.alloc(u8, 1);
    defer for (0..k) |i| alloc.free(out[i]);

    try rs.decode(alloc, &idx, &recv, &out);
    try std.testing.expectEqual(@as(u8, 0xDE), out[0][0]);
    try std.testing.expectEqual(@as(u8, 0xAD), out[1][0]);
    try std.testing.expectEqual(@as(u8, 0xBE), out[2][0]);
}
