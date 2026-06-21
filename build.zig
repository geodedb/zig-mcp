// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Thread-pool parallelism option
    const enable_tp = b.option(bool, "thread-pool", "Enable thread-pool-based parallelism") orelse true;

    // -Dwith_otel: compile in otel instrumentation. OFF by default;
    // when off the otel dependency is never resolved and the seam
    // collapses to a comptime-known no-op (verified by
    // otel/scripts/verify-consumer-noop.sh).
    const with_otel = b.option(
        bool,
        "with_otel",
        "Compile in otel instrumentation (off by default; zero overhead when off)",
    ) orelse false;

    // SHARED `build_options` module. Every consumer of the
    // `observability` seam imports the SAME module instance via
    // `addImport` so Zig 0.16's "file exists in modules X and X0"
    // diagnostic doesn't trip when two independent `addOptions` modules
    // would otherwise share a transitive file path.
    // -Dfips: route security crypto through the linked OpenSSL FIPS-140-3
    // provider. OFF by default with zero overhead; the lazy `fips` dependency
    // is resolved only when this is true.
    const fips = b.option(bool, "fips", "Route security crypto through the linked FIPS-140-3 provider (off by default; zero overhead when off)") orelse false;
    const openssl_path = b.option([]const u8, "openssl_path", "OpenSSL install prefix for non-standard installs (e.g. /usr/local/ssl)");
    const link = @import("src/link.zig");

    const build_options = b.addOptions();
    build_options.addOption(bool, "with_otel", with_otel);
    build_options.addOption(bool, "fips", fips);
    const build_options_mod = build_options.createModule();

    // FIPS seam — SHARED NAMED `crypto_backend` module on the SAME single
    // `build_options` instance as the otel seam (GAP-0020-safe). The lazy
    // `fips` dep + OpenSSL link are pulled only when -Dfips=true.
    const crypto_backend_mod = b.addModule("crypto_backend", .{
        .root_source_file = b.path("src/crypto_backend.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = build_options_mod }},
    });
    const std_shim_mod = b.addModule("std_shim", .{
        .root_source_file = b.path("src/std_shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    crypto_backend_mod.addImport("std_shim", std_shim_mod);
    if (fips) {
        if (b.lazyDependency("fips", .{ .target = target, .optimize = optimize, .openssl_path = openssl_path orelse "/usr/local/ssl" })) |fips_dep| {
            const fm = fips_dep.module("fips");
            crypto_backend_mod.addImport("fips", fm);
            link.linkOpenssl(b, fm, openssl_path);
        }
    }

    // Observability seam (otel). Declared as a SHARED NAMED MODULE so
    // every consumer (mcp lib + tests) resolves to the same source file
    // via `@import("observability")`. Using a relative
    // `@import("observability.zig")` from each module would trip Zig's
    // "file exists in modules X and Y" error because the file would be
    // pulled into multiple module trees. The seam's `enabled` flag
    // tracks `build_options.with_otel`; when off, every helper compiles
    // to a comptime-known no-op and the otel dependency is never
    // resolved. The optional `otel` import is wired below inside the
    // `if (with_otel)` block.
    const observability_mod = b.addModule("observability", .{
        .root_source_file = b.path("src/observability.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    // Get thread_pool dependency if enabled
    const tp_mod: ?*std.Build.Module = if (enable_tp) blk: {
        const tp_dep = b.dependency("thread_pool", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk tp_dep.module("thread_pool");
    } else null;

    // External Dependencies
    const use_json = b.option(bool, "json", "Use internal json dependency") orelse true;
    const json_mod: ?*std.Build.Module = if (use_json) blk: {
        const json_dep = b.dependency("json", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk json_dep.module("json");
    } else null;

    // ========================================================================
    // Core Modules
    // ========================================================================

    // Log module
    const log_mod = b.addModule("log", .{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = optimize,
    });

    // TLS module
    const tls_mod = b.addModule("tls", .{
        .root_source_file = b.path("src/tls.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Zero-copy module
    const zero_copy_mod = b.addModule("zero_copy", .{
        .root_source_file = b.path("src/zero_copy.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (json_mod) |m| zero_copy_mod.addImport("json", m);

    // Pipelining module
    const pipelining_mod = b.addModule("pipelining", .{
        .root_source_file = b.path("src/pipelining.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Parallel module
    const parallel_mod: ?*std.Build.Module = if (enable_tp) blk: {
        break :blk b.addModule("parallel", .{
            .root_source_file = b.path("src/parallel.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        });
    } else null;
    if (parallel_mod) |pm| {
        if (tp_mod) |tm| pm.addImport("thread_pool", tm);
    }

    // Main MCP module
    const mcp_mod = b.addModule("mcp", .{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });
    if (json_mod) |m| mcp_mod.addImport("json", m);
    if (tp_mod) |tm| mcp_mod.addImport("thread_pool", tm);
    // Observability seam: wire the named `observability` module onto
    // the public `mcp` module so consumers reach the seam through
    // `mcp.observability`. The seam itself is comptime-gated by
    // `build_options.with_otel` and collapses to a no-op when off.
    mcp_mod.addImport("observability", observability_mod);
    mcp_mod.addImport("build_options", build_options_mod);
    mcp_mod.addImport("crypto_backend", crypto_backend_mod);

    // Server extensions module
    const server_ext_mod = b.addModule("server_ext", .{
        .root_source_file = b.path("src/server_ext.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mcp", .module = mcp_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "crypto_backend", .module = crypto_backend_mod },
        },
    });

    // ========================================================================
    // CLI Executables
    // ========================================================================

    // MCP Server Runner
    const mcp_server = b.addExecutable(.{
        .name = "mcp-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/mcp-server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mcp", .module = mcp_mod },
                .{ .name = "log", .module = log_mod },
            },
        }),
    });
    b.installArtifact(mcp_server);

    // MCP Protocol Inspector
    const mcp_inspect_mod = b.createModule(.{
        .root_source_file = b.path("cmd/mcp-inspect/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (json_mod) |m| mcp_inspect_mod.addImport("json", m);
    const mcp_inspect = b.addExecutable(.{
        .name = "mcp-inspect",
        .root_module = mcp_inspect_mod,
    });
    b.installArtifact(mcp_inspect);

    // MCP Test Client
    const mcp_client_mod = b.createModule(.{
        .root_source_file = b.path("cmd/mcp-client/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (json_mod) |m| mcp_client_mod.addImport("json", m);
    const mcp_client = b.addExecutable(.{
        .name = "mcp-client",
        .root_module = mcp_client_mod,
    });
    b.installArtifact(mcp_client);

    // Run steps for CLI tools
    const run_server = b.addRunArtifact(mcp_server);
    const run_inspect = b.addRunArtifact(mcp_inspect);
    const run_client = b.addRunArtifact(mcp_client);

    if (b.args) |args| {
        run_server.addArgs(args);
        run_inspect.addArgs(args);
        run_client.addArgs(args);
    }

    const run_server_step = b.step("run-server", "Run MCP server");
    run_server_step.dependOn(&run_server.step);

    const run_inspect_step = b.step("run-inspect", "Run MCP inspector");
    run_inspect_step.dependOn(&run_inspect.step);

    const run_client_step = b.step("run-client", "Run MCP test client");
    run_client_step.dependOn(&run_client.step);

    // ========================================================================
    // Examples
    // ========================================================================

    const example_sources = [_]struct { name: []const u8, file: []const u8, needs_mcp: bool }{
        .{ .name = "example-basic-server", .file = "examples/01_basic_server.zig", .needs_mcp = true },
        .{ .name = "example-http-server", .file = "examples/02_http_server.zig", .needs_mcp = true },
        .{ .name = "example-tool-registration", .file = "examples/03_tool_registration.zig", .needs_mcp = true },
        .{ .name = "example-resources", .file = "examples/04_resources_and_prompts.zig", .needs_mcp = true },
        .{ .name = "example-auth", .file = "examples/05_authentication.zig", .needs_mcp = true },
        .{ .name = "example-client", .file = "examples/06_client_example.zig", .needs_mcp = false },
        .{ .name = "example-notifications", .file = "examples/07_notifications.zig", .needs_mcp = true },
    };

    for (example_sources) |example| {
        const imports: []const std.Build.Module.Import = if (example.needs_mcp)
            &.{.{ .name = "mcp", .module = mcp_mod }}
        else
            &.{};

        const example_exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.file),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });
        b.installArtifact(example_exe);

        const run_example = b.addRunArtifact(example_exe);
        if (b.args) |args| {
            run_example.addArgs(args);
        }

        // Create run step with "run-" prefix
        const step_name = b.fmt("run-{s}", .{example.name});
        const step_desc = b.fmt("Run {s}", .{example.name});
        const run_step = b.step(step_name, step_desc);
        run_step.dependOn(&run_example.step);
    }

    // ========================================================================
    // Test Configuration
    // ========================================================================

    const test_step = b.step("test", "Run all tests");

    // Unit tests for main module
    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (json_mod) |m| unit_test_mod.addImport("json", m);
    if (tp_mod) |tm| unit_test_mod.addImport("thread_pool", tm);
    // Observability seam imports must match `mcp_mod` so the unit-test
    // root resolves the same `observability` / `build_options` module
    // instances (avoids "file exists in modules X and X0").
    unit_test_mod.addImport("observability", observability_mod);
    unit_test_mod.addImport("build_options", build_options_mod);
    unit_test_mod.addImport("crypto_backend", crypto_backend_mod);
    const unit_test = b.addTest(.{
        .root_module = unit_test_mod,
    });
    const run_unit_test = b.addRunArtifact(unit_test);
    test_step.dependOn(&run_unit_test.step);

    // Log module tests
    const log_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/log.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_log_test = b.addRunArtifact(log_test);
    test_step.dependOn(&run_log_test.step);

    // TLS module tests
    const tls_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tls.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "crypto_backend", .module = crypto_backend_mod },
            },
        }),
    });
    const run_tls_test = b.addRunArtifact(tls_test);
    test_step.dependOn(&run_tls_test.step);

    // Zero-copy module tests
    const zero_copy_test_mod = b.createModule(.{
        .root_source_file = b.path("src/zero_copy.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (json_mod) |m| zero_copy_test_mod.addImport("json", m);
    const zero_copy_test = b.addTest(.{
        .root_module = zero_copy_test_mod,
    });
    const run_zero_copy_test = b.addRunArtifact(zero_copy_test);
    test_step.dependOn(&run_zero_copy_test.step);

    // Pipelining module tests
    const pipelining_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pipelining.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_pipelining_test = b.addRunArtifact(pipelining_test);
    test_step.dependOn(&run_pipelining_test.step);

    // Server extensions tests
    const server_ext_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server_ext.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mcp", .module = mcp_mod },
                .{ .name = "log", .module = log_mod },
            },
        }),
    });
    const run_server_ext_test = b.addRunArtifact(server_ext_test);
    test_step.dependOn(&run_server_ext_test.step);

    // Acceptance tests
    const accept_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/accept.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mcp", .module = mcp_mod },
        },
    });
    if (json_mod) |m| accept_test_mod.addImport("json", m);
    if (tp_mod) |tm| accept_test_mod.addImport("thread_pool", tm);
    const accept_test = b.addTest(.{
        .root_module = accept_test_mod,
    });
    const run_accept_test = b.addRunArtifact(accept_test);
    test_step.dependOn(&run_accept_test.step);

    // Conformance tests
    const conformance_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mcp", .module = mcp_mod },
        },
    });
    if (json_mod) |m| conformance_test_mod.addImport("json", m);
    const conformance_test = b.addTest(.{
        .root_module = conformance_test_mod,
    });
    const run_conformance_test = b.addRunArtifact(conformance_test);
    test_step.dependOn(&run_conformance_test.step);

    // Separate test steps
    const test_accept_step = b.step("test-accept", "Run acceptance tests only");
    test_accept_step.dependOn(&run_accept_test.step);

    const test_conformance_step = b.step("test-conformance", "Run conformance tests only");
    test_conformance_step.dependOn(&run_conformance_test.step);

    // ========================================================================
    // Fuzz Testing
    // ========================================================================

    const fuzz_exe_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mcp", .module = mcp_mod },
        },
    });
    if (json_mod) |m| fuzz_exe_mod.addImport("json", m);
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = fuzz_exe_mod,
    });
    b.installArtifact(fuzz_exe);

    const run_fuzz = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| {
        run_fuzz.addArgs(args);
    }
    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    fuzz_step.dependOn(&run_fuzz.step);

    // ========================================================================
    // Benchmarks
    // ========================================================================

    const bench_exe_mod = b.createModule(.{
        .root_source_file = b.path("tests/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "mcp", .module = mcp_mod },
        },
    });
    if (json_mod) |m| bench_exe_mod.addImport("json", m);
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_exe_mod,
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // ========================================================================
    // Documentation (placeholder for future doc generation)
    // ========================================================================

    const docs_step = b.step("docs", "Generate documentation");
    _ = docs_step;

    // Expose modules for external use
    _ = tls_mod;
    _ = pipelining_mod;
    _ = server_ext_mod;

    // ========================================================================
    // Observability seam (otel) — gated dep + tests
    // ========================================================================

    // Gated otel dependency. The `lazy = true` entry in build.zig.zon
    // means Zig only fetches the package when this branch executes;
    // with the flag off the dependency is never resolved and the
    // produced artifacts contain zero otel symbols (verified by
    // otel/scripts/verify-consumer-noop.sh).
    if (with_otel) {
        const otel_dep = b.lazyDependency("otel", .{
            .target = target,
            .optimize = optimize,
        }) orelse return;
        const otel_module = otel_dep.module("otel");
        // The seam imports `otel` when enabled. Wire it onto the shared
        // observability module so every consumer sees the same otel
        // namespace. Also wire onto the public `mcp` module so callers
        // who reach for `@import("otel")` directly through `mcp_mod`'s
        // tree can find it (consistent with dns/grpc-zig).
        observability_mod.addImport("otel", otel_module);
        mcp_mod.addImport("otel", otel_module);

        // Bootstrap helper. Only registered when `-Dwith_otel=true` so
        // the disabled build never compiles otel-touching code. Gated
        // from src/mcp.zig via `if (observability.enabled) @import("observability_init")`.
        const observability_init_mod = b.addModule("observability_init", .{
            .root_source_file = b.path("src/observability_init.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "otel", .module = otel_module },
                .{ .name = "observability", .module = observability_mod },
            },
        });
        mcp_mod.addImport("observability_init", observability_init_mod);
    }

    // Disabled-mode no-op tests. Verifies `build_options.with_otel ==
    // false` is the default and that the seam's public surface returns
    // a comptime-known no-op when otel is off. The test is skip-guarded
    // for the enabled build so it passes under both flag values.
    const observability_disabled_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/observability_disabled_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mcp", .module = mcp_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    const run_observability_disabled_tests = b.addRunArtifact(observability_disabled_tests);
    test_step.dependOn(&run_observability_disabled_tests.step);

    // Enabled-mode smoke test. Skips under -Dwith_otel=false; under
    // -Dwith_otel=true it installs an in-memory recorder, drives one
    // RPC span through the seam, and asserts the recorder captured it.
    // Compiles cleanly under both flag values because the otel-namespace
    // identifiers sit behind `comptime if (enabled)` short-circuits.
    const observability_enabled_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/observability_enabled_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mcp", .module = mcp_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    if (with_otel) {
        // Re-resolve the otel module under the same `with_otel` guard
        // so the smoke test reaches `@import("otel")`. The earlier
        // `lazyDependency` call handles `mcp_mod`; the test root needs
        // its own import wire.
        const otel_dep = b.lazyDependency("otel", .{
            .target = target,
            .optimize = optimize,
        }) orelse return;
        observability_enabled_tests.root_module.addImport("otel", otel_dep.module("otel"));
    }
    const run_observability_enabled_tests = b.addRunArtifact(observability_enabled_tests);
    test_step.dependOn(&run_observability_enabled_tests.step);
}
