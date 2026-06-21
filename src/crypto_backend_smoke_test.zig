// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
const std = @import("std");
const crypto_backend = @import("crypto_backend");

test "mcp crypto_backend seam exposes fips_enabled flag + Hash" {
    // fips_enabled is comptime-known; default build is false.
    if (!crypto_backend.fips_enabled) {
        var out: [32]u8 = undefined;
        _ = try crypto_backend.Hash.digest(.sha256, "abc", &out);
    }
    crypto_backend.assertActive();
}
