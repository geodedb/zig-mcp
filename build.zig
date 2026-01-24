// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // External Dependencies
    const json_dep = b.dependency("json", .{
        .target = target,
        .optimize = optimize,
    });
    const json_mod = json_dep.module("json");

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
        .imports = &.{
            .{ .name = "json", .module = json_mod },
        },
    });

    // Pipelining module
    const pipelining_mod = b.addModule("pipelining", .{
        .root_source_file = b.path("src/pipelining.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main MCP module
    const mcp_mod = b.addModule("mcp", .{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json", .module = json_mod },
        },
    });

    // Server extensions module
    const server_ext_mod = b.addModule("server_ext", .{
        .root_source_file = b.path("src/server_ext.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mcp", .module = mcp_mod },
            .{ .name = "log", .module = log_mod },
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
    const mcp_inspect = b.addExecutable(.{
        .name = "mcp-inspect",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/mcp-inspect/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "json", .module = json_mod },
            },
        }),
    });
    b.installArtifact(mcp_inspect);

    // MCP Test Client
    const mcp_client = b.addExecutable(.{
        .name = "mcp-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/mcp-client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "json", .module = json_mod },
            },
        }),
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
    const unit_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "json", .module = json_mod },
            },
        }),
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
        }),
    });
    const run_tls_test = b.addRunArtifact(tls_test);
    test_step.dependOn(&run_tls_test.step);

    // Zero-copy module tests
    const zero_copy_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zero_copy.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "json", .module = json_mod },
            },
        }),
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
    const accept_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/accept.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mcp", .module = mcp_mod },
                .{ .name = "json", .module = json_mod },
            },
        }),
    });
    const run_accept_test = b.addRunArtifact(accept_test);
    test_step.dependOn(&run_accept_test.step);

    // Conformance tests
    const conformance_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mcp", .module = mcp_mod },
                .{ .name = "json", .module = json_mod },
            },
        }),
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

    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mcp", .module = mcp_mod },
                .{ .name = "json", .module = json_mod },
            },
        }),
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

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "mcp", .module = mcp_mod },
                .{ .name = "json", .module = json_mod },
            },
        }),
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
    _ = zero_copy_mod;
    _ = pipelining_mod;
    _ = server_ext_mod;
}
