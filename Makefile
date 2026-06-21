# MCP Library Makefile
#
# Development workflow targets for the MCP Zig library.

.PHONY: all build test clean check fmt dev ci help

# Default target - build and test everything
all: build test

# ============================================================
# Core Targets
# ============================================================

# Build the library
build:
	zig build --summary all

# Run all unit tests
test:
	zig build test --summary all

# Clean build artifacts
clean:
	rm -rf zig-out zig-cache .zig-cache

# Check syntax without building
check:
	zig build --summary all -fno-emit-bin

# Format all Zig source files
fmt:
	zig fmt src/ tests/ build.zig

# ============================================================
# Test Categories
# ============================================================

# Run utility module tests
test-util:
	zig build test-util --summary all

# Run transport module tests
test-transport:
	zig build test-transport --summary all

# Run server module tests
test-server:
	zig build test-server --summary all

# Run client module tests
test-client:
	zig build test-client --summary all

# Run acceptance tests
test-accept:
	zig build test-accept --summary all

# ============================================================
# Optimization Testing
# ============================================================

# Run tests with Debug optimization
test-debug:
	zig build test -Doptimize=Debug --summary all

# Run tests with ReleaseSafe optimization
test-release-safe:
	zig build test -Doptimize=ReleaseSafe --summary all

# Run tests with ReleaseFast optimization
test-release-fast:
	zig build test -Doptimize=ReleaseFast --summary all

# Run tests with ReleaseSmall optimization
test-release-small:
	zig build test -Doptimize=ReleaseSmall --summary all

# Run all optimization level tests
test-all-optimizations: test-debug test-release-safe test-release-fast test-release-small

# ============================================================
# Development Workflow
# ============================================================

# Quick development workflow (format + check + test)
dev: fmt check test

# Full CI pipeline (clean + build + test)
ci: clean build test test-all-optimizations

# Watch for changes and rebuild (requires entr)
watch:
	find src tests build.zig -name '*.zig' | entr -c make dev

# ============================================================
# Cross-Compilation
# ============================================================

# Build for ARM Linux
build-arm-linux:
	zig build -Dtarget=arm-linux-gnueabihf

# Build for ARM64 Linux
build-aarch64-linux:
	zig build -Dtarget=aarch64-linux-gnu

# Build for RISC-V 64 Linux
build-riscv64-linux:
	zig build -Dtarget=riscv64-linux-gnu

# Build for x86_64 macOS
build-x86_64-macos:
	zig build -Dtarget=x86_64-macos

# Build for ARM64 macOS
build-aarch64-macos:
	zig build -Dtarget=aarch64-macos

# Build for x86_64 Windows
build-x86_64-windows:
	zig build -Dtarget=x86_64-windows-gnu

# Build for ARM64 Windows
build-aarch64-windows:
	zig build -Dtarget=aarch64-windows-gnu

# Build all cross-compilation targets
build-all-targets: build-arm-linux build-aarch64-linux build-riscv64-linux \
                   build-x86_64-macos build-aarch64-macos \
                   build-x86_64-windows build-aarch64-windows

# ============================================================
# Documentation
# ============================================================

# Generate documentation (if zig doc is available)
docs:
	zig build-lib src/lib.zig -femit-docs -fno-emit-bin || echo "Documentation generation requires zig build-lib support"

# ============================================================
# Help
# ============================================================

help:
	@echo "MCP Library Development Targets"
	@echo ""
	@echo "Core:"
	@echo "  make build              - Build the library"
	@echo "  make test               - Run all unit tests"
	@echo "  make clean              - Remove build artifacts"
	@echo "  make check              - Check syntax without building"
	@echo "  make fmt                - Format source files"
	@echo ""
	@echo "Test Categories:"
	@echo "  make test-util          - Run utility module tests"
	@echo "  make test-transport     - Run transport module tests"
	@echo "  make test-server        - Run server module tests"
	@echo "  make test-client        - Run client module tests"
	@echo "  make test-accept        - Run acceptance tests"
	@echo ""
	@echo "Optimization Testing:"
	@echo "  make test-debug         - Test with Debug optimization"
	@echo "  make test-release-safe  - Test with ReleaseSafe optimization"
	@echo "  make test-release-fast  - Test with ReleaseFast optimization"
	@echo "  make test-release-small - Test with ReleaseSmall optimization"
	@echo "  make test-all-optimizations - Run all optimization level tests"
	@echo ""
	@echo "Development:"
	@echo "  make dev                - Quick dev workflow (fmt + check + test)"
	@echo "  make ci                 - Full CI pipeline"
	@echo "  make watch              - Watch for changes and rebuild"
	@echo ""
	@echo "Cross-Compilation:"
	@echo "  make build-arm-linux    - Build for ARM Linux"
	@echo "  make build-aarch64-linux - Build for ARM64 Linux"
	@echo "  make build-riscv64-linux - Build for RISC-V 64 Linux"
	@echo "  make build-x86_64-macos - Build for x86_64 macOS"
	@echo "  make build-aarch64-macos - Build for ARM64 macOS"
	@echo "  make build-x86_64-windows - Build for x86_64 Windows"
	@echo "  make build-aarch64-windows - Build for ARM64 Windows"
	@echo "  make build-all-targets  - Build all cross-compilation targets"

.PHONY: test-fips test-dual
# FIPS-140-3 dual-mode test (-Dfips=true). Requires the OpenSSL FIPS
# provider at $(or $(OPENSSL_PREFIX),/usr/local/ssl) (run `make deps` first).
test-fips:
	OPENSSL_CONF=$(or $(OPENSSL_PREFIX),/usr/local/ssl)/ssl/openssl.cnf zig build test -Dfips=true -Dopenssl_path=$(or $(OPENSSL_PREFIX),/usr/local/ssl) --summary all

test-dual: test test-fips
