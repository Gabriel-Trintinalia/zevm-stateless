//! ere-server: standalone Twirp HTTP/1.1 server exposing the ZkvmService interface.
//!
//! Usage:
//!   ere-server           # listen on :50051 (default)
//!   ere-server 50052     # listen on a custom port
//!
//! Implements the ere-compatible Twirp interface expected by zkboost:
//!   GET  /health                              → 200 OK
//!   POST /twirp/api.ZkvmService/Execute       → ExecuteOk protobuf
//!   POST /twirp/api.ZkvmService/Prove         → ProveOk protobuf
//!
//! Proto wire format (manually encoded — no proto library needed):
//!   ExecuteRequest / ProveRequest: field 1 (tag=0x0A) = bytes input_stdin (SSZ)
//!   ExecuteOk:  field 1 (0x0A) = bytes public_values, field 2 (0x12) = bytes report (empty)
//!   ProveOk:    field 1 (0x0A) = bytes public_values, field 2 (0x12) = bytes proof (empty), field 3 (0x1A) = bytes report (empty)

const std = @import("std");
const executor = @import("executor");
const ssz_decode = @import("ssz_decode");
const alloc_mod = @import("main_allocator");

const log = std.log.scoped(.ere_server);

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main() !void {
    const alloc = alloc_mod.get();

    const args = try std.process.argsAlloc(alloc);
    var port: u16 = 50051;

    if (args.len > 1) {
        port = std.fmt.parseInt(u16, args[1], 10) catch {
            std.debug.print("usage: ere-server [port]\n", .{});
            std.process.exit(1);
        };
    }

    try serve(alloc, port);
}

// ── Protobuf helpers ──────────────────────────────────────────────────────────

fn writeVarint(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u64) !void {
    var n = v;
    while (n >= 0x80) {
        try list.append(alloc, @intCast((n & 0x7F) | 0x80));
        n >>= 7;
    }
    try list.append(alloc, @intCast(n));
}

/// Write a length-delimited protobuf field: tag byte + varint(len) + data.
fn writeField(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, tag: u8, data: []const u8) !void {
    try list.append(alloc, tag);
    try writeVarint(list, alloc, data.len);
    try list.appendSlice(alloc, data);
}

const ParsedField = struct {
    field_number: u32,
    wire_type: u3,
    value: []const u8, // populated for wire_type 2 (length-delimited)
    consumed: usize,
};

fn readField(data: []const u8) !ParsedField {
    if (data.len == 0) return error.InvalidProtobuf;
    var tag: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const b = data[i];
        tag |= @as(u64, b & 0x7F) << shift;
        shift += 7;
        if (b & 0x80 == 0) { i += 1; break; }
        if (shift >= 64) return error.InvalidProtobuf;
    }
    const field_number: u32 = @intCast(tag >> 3);
    const wire_type: u3 = @intCast(tag & 0x7);
    if (wire_type != 2) return .{ .field_number = field_number, .wire_type = wire_type, .value = &.{}, .consumed = i };

    var length: u64 = 0;
    var ls: u6 = 0;
    while (i < data.len) : (i += 1) {
        const b = data[i];
        length |= @as(u64, b & 0x7F) << ls;
        ls += 7;
        if (b & 0x80 == 0) { i += 1; break; }
        if (ls >= 64) return error.InvalidProtobuf;
    }
    const end = i + length;
    if (end > data.len) return error.InvalidProtobuf;
    return .{ .field_number = field_number, .wire_type = wire_type, .value = data[i..end], .consumed = end };
}

// ── HTTP helpers ──────────────────────────────────────────────────────────────

const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

fn readRequest(stream: std.net.Stream, alloc: std.mem.Allocator) !Request {
    var buf = std.ArrayListUnmanaged(u8){};
    var tmp: [4096]u8 = undefined;
    var header_end: ?usize = null;

    while (header_end == null) {
        const n = try stream.read(&tmp);
        if (n == 0) return error.ConnectionClosed;
        try buf.appendSlice(alloc, tmp[0..n]);
        header_end = std.mem.indexOf(u8, buf.items, "\r\n\r\n");
    }

    const hdr_end = header_end.?;
    const headers_str = buf.items[0..hdr_end];
    const body_start = hdr_end + 4;

    var lines = std.mem.splitScalar(u8, headers_str, '\n');
    const request_line = std.mem.trim(u8, lines.next() orelse "", " \r");
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = try alloc.dupe(u8, parts.next() orelse "");
    const path_raw = parts.next() orelse "";
    const path = try alloc.dupe(u8, if (std.mem.indexOfScalar(u8, path_raw, '?')) |q| path_raw[0..q] else path_raw);

    var content_length: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const val = std.mem.trim(u8, trimmed["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }

    while (buf.items.len - body_start < content_length) {
        const n = stream.read(&tmp) catch break;
        if (n == 0) break;
        try buf.appendSlice(alloc, tmp[0..n]);
    }

    const body_end = @min(body_start + content_length, buf.items.len);
    return .{ .method = method, .path = path, .body = buf.items[body_start..body_end] };
}

fn writeResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len }) catch return;
    _ = stream.writeAll(h) catch {};
    _ = stream.writeAll(body) catch {};
}

fn twirpError(stream: std.net.Stream, code: []const u8, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"code\":\"{s}\",\"msg\":\"{s}\"}}", .{ code, msg }) catch return;
    writeResponse(stream, "400 Bad Request", "application/json", body);
}

// ── Connection handler ────────────────────────────────────────────────────────

fn handleConn(alloc: std.mem.Allocator, stream: std.net.Stream) void {
    const req = readRequest(stream, alloc) catch |err| {
        log.err("read request: {}", .{err});
        return;
    };

    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/health")) {
        writeResponse(stream, "200 OK", "text/plain", "ok");
        return;
    }

    const is_execute = std.mem.eql(u8, req.path, "/twirp/api.ZkvmService/Execute");
    const is_prove = std.mem.eql(u8, req.path, "/twirp/api.ZkvmService/Prove");

    if (!std.mem.eql(u8, req.method, "POST") or (!is_execute and !is_prove)) {
        twirpError(stream, "bad_route", "unknown route");
        return;
    }

    // Extract field 1 (input_stdin) from ExecuteRequest / ProveRequest
    var input_stdin: ?[]const u8 = null;
    var rest = req.body;
    while (rest.len > 0) {
        const f = readField(rest) catch break;
        if (f.field_number == 1 and f.wire_type == 2) input_stdin = f.value;
        rest = rest[f.consumed..];
    }

    const stdin_bytes = input_stdin orelse {
        twirpError(stream, "invalid_argument", "missing input_stdin");
        return;
    };

    // Decode SSZ → StatelessInput
    const si = ssz_decode.decode(alloc, stdin_bytes) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "SSZ decode: {}", .{err}) catch "SSZ decode failed";
        twirpError(stream, "invalid_argument", msg);
        return;
    };

    // Execute block
    const proof_out = executor.executeStatelessInput(alloc, si, null) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "execution: {}", .{err}) catch "execution failed";
        twirpError(stream, "internal", msg);
        return;
    };

    const ep = &si.new_payload_request.execution_payload;

    // Serialize public_values as JSON
    const pre_hex = std.fmt.bytesToHex(proof_out.pre_state_root, .lower);
    const post_hex = std.fmt.bytesToHex(proof_out.post_state_root, .lower);
    const rcpt_hex = std.fmt.bytesToHex(proof_out.receipts_root, .lower);
    var json_buf: [512]u8 = undefined;
    const public_values = std.fmt.bufPrint(&json_buf,
        "{{\"block\":{d},\"valid\":true," ++
        "\"pre_state_root\":\"0x{s}\"," ++
        "\"post_state_root\":\"0x{s}\"," ++
        "\"receipts_root\":\"0x{s}\"}}",
        .{ ep.block_number, pre_hex, post_hex, rcpt_hex }) catch {
        twirpError(stream, "internal", "serialize result failed");
        return;
    };

    // Encode protobuf response (ExecuteOk or ProveOk)
    var proto = std.ArrayListUnmanaged(u8){};
    writeField(&proto, alloc, 0x0A, public_values) catch { // field 1: public_values
        twirpError(stream, "internal", "encode proto failed");
        return;
    };
    writeField(&proto, alloc, 0x12, &.{}) catch {}; // field 2: report/proof (empty)
    if (is_prove) writeField(&proto, alloc, 0x1A, &.{}) catch {}; // field 3: report (empty, ProveOk only)

    writeResponse(stream, "200 OK", "application/protobuf", proto.items);
}

// ── Server loop ───────────────────────────────────────────────────────────────

fn serve(alloc: std.mem.Allocator, port: u16) !void {
    const addr = try std.net.Address.parseIp4("0.0.0.0", port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    log.info("ere-server listening on :{d}", .{port});

    while (true) {
        const conn = server.accept() catch |err| {
            log.err("accept: {}", .{err});
            continue;
        };
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        handleConn(arena.allocator(), conn.stream);
        conn.stream.close();
    }
}
