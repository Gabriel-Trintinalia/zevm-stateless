const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Platform-aware crypto library prefix: Homebrew on macOS, /usr/local on Linux
    const is_linux = b.graph.host.result.os.tag == .linux;
    const crypto_prefix = if (is_linux) "/usr/local" else "/opt/homebrew";
    const crypto_include = b.fmt("{s}/include", .{crypto_prefix});
    const libblst_path = b.fmt("{s}/lib/libblst.a", .{crypto_prefix});
    const libmcl_path = b.fmt("{s}/lib/libmcl.a", .{crypto_prefix});

    // mcl is built with g++ on Linux, which embeds libstdc++ symbol references
    // into the .a archive. Zig's LLD cannot resolve these against the system
    // libstdc++ reliably. The .so avoids the problem: its C++ deps are resolved
    // at load time by the OS dynamic linker. On macOS, Homebrew mcl is compiled
    // with clang/libc++ so static linking with linkLibCpp() works correctly.
    const addMcl = struct {
        fn call(step: *std.Build.Step.Compile, linux: bool, mcl_path: []const u8) void {
            if (linux) {
                step.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
                step.linkSystemLibrary("mcl");
            } else {
                step.addObjectFile(.{ .cwd_relative = mcl_path });
                step.linkLibCpp();
            }
        }
    }.call;

    // zevm dependency
    const zevm_dep = b.dependency("zevm", .{
        .target = target,
        .optimize = optimize,
    });

    const primitives = zevm_dep.module("primitives");
    const bytecode = zevm_dep.module("bytecode");
    const state = zevm_dep.module("state");
    const database = zevm_dep.module("database");
    const context = zevm_dep.module("context");
    const interpreter = zevm_dep.module("interpreter");
    const precompile = zevm_dep.module("precompile");
    const handler = zevm_dep.module("handler");
    const inspector = zevm_dep.module("inspector");

    // Local modules
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("primitives", primitives);

    const output_mod = b.addModule("output", .{
        .root_source_file = b.path("src/output.zig"),
        .target = target,
        .optimize = optimize,
    });
    output_mod.addImport("primitives", primitives);

    // Default keccak_impl — pure-Zig std.crypto wrapper.
    // Overridden in Zisk builds to inject the hardware keccakf circuit:
    //   mpt_mod.addImport("keccak_impl", your_hw_keccak_module)
    const keccak_impl_mod = b.addModule("keccak_impl", .{
        .root_source_file = b.path("src/mpt/keccak_impl.zig"),
        .target = target,
        .optimize = optimize,
    });

    // mpt_nibbles: shared nibble utilities — standalone so mpt and mpt_builder can both use it
    const mpt_nibbles_mod = b.createModule(.{
        .root_source_file = b.path("src/mpt/nibbles.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mpt_mod = b.addModule("mpt", .{
        .root_source_file = b.path("src/mpt/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mpt_mod.addImport("primitives", primitives);
    mpt_mod.addImport("input", input_mod);
    mpt_mod.addImport("mpt_nibbles", mpt_nibbles_mod);
    mpt_mod.addImport("keccak_impl", keccak_impl_mod);

    // rlp_decode — single source of truth for raw RLP → input types
    const rlp_decode_mod = b.addModule("rlp_decode", .{
        .root_source_file = b.path("src/rlp_decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    rlp_decode_mod.addImport("input", input_mod);
    rlp_decode_mod.addImport("primitives", primitives);
    rlp_decode_mod.addImport("mpt", mpt_mod);

    const db_mod = b.addModule("db", .{
        .root_source_file = b.path("src/db/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    db_mod.addImport("primitives", primitives);
    db_mod.addImport("state", state);
    db_mod.addImport("bytecode", bytecode);
    db_mod.addImport("mpt", mpt_mod);
    db_mod.addImport("input", input_mod);

    // mpt_builder: standalone trie builder (shares nibbles with mpt via mpt_nibbles)
    const mpt_builder_mod = b.addModule("mpt_builder", .{
        .root_source_file = b.path("src/mpt/builder.zig"),
        .target = target,
        .optimize = optimize,
    });
    mpt_builder_mod.addImport("mpt_nibbles", mpt_nibbles_mod);

    const executor_mod = b.addModule("executor", .{
        .root_source_file = b.path("src/executor/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    executor_mod.addImport("primitives", primitives);
    executor_mod.addImport("state", state);
    executor_mod.addImport("bytecode", bytecode);
    executor_mod.addImport("database", database);
    executor_mod.addImport("handler", handler);
    executor_mod.addImport("precompile", precompile);
    executor_mod.addImport("mpt", mpt_mod);
    executor_mod.addImport("mpt_builder", mpt_builder_mod);
    executor_mod.addImport("db", db_mod);
    executor_mod.addImport("input", input_mod);
    executor_mod.addImport("output", output_mod);
    // Note: named executor sub-modules (executor_fork, executor_tx_decode, etc.)
    // are added further below, after those module variables are created.

    const mod = b.addModule("zevm_stateless", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("primitives", primitives);
    mod.addImport("input", input_mod);
    mod.addImport("output", output_mod);
    mod.addImport("mpt", mpt_mod);
    mod.addImport("db", db_mod);
    mod.addImport("executor", executor_mod);

    // main_allocator — injectable allocator for the zevm_stateless binary.
    // Default: std.heap.c_allocator (suitable for native builds).
    // Override for zkVM builds:
    //   exe.root_module.addImport("main_allocator", your_alloc_module)
    const main_allocator_mod = b.createModule(.{
        .root_source_file = b.path("src/zkvm/allocator.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // zkvm_io — injectable I/O module for the zevm_stateless binary.
    // Default: reads from stdin, writes to stdout (suitable for native builds).
    // Override for zkVM builds:
    //   exe.root_module.addImport("zkvm_io", your_io_module)
    const zkvm_io_mod = b.createModule(.{
        .root_source_file = b.path("src/zkvm/io.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zevm_stateless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stateless/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zevm_stateless", .module = mod },
            },
        }),
    });

    exe.root_module.addImport("primitives", primitives);
    exe.root_module.addImport("bytecode", bytecode);
    exe.root_module.addImport("state", state);
    exe.root_module.addImport("database", database);
    exe.root_module.addImport("context", context);
    exe.root_module.addImport("interpreter", interpreter);
    exe.root_module.addImport("precompile", precompile);
    exe.root_module.addImport("handler", handler);
    exe.root_module.addImport("inspector", inspector);
    exe.root_module.addImport("input", input_mod);
    exe.root_module.addImport("output", output_mod);
    exe.root_module.addImport("mpt", mpt_mod);
    exe.root_module.addImport("db", db_mod);
    exe.root_module.addImport("executor", executor_mod);
    exe.root_module.addImport("rlp_decode", rlp_decode_mod);
    exe.root_module.addImport("main_allocator", main_allocator_mod);
    exe.root_module.addImport("zkvm_io", zkvm_io_mod);

    // Link crypto libraries required by native_executor_transition (secp256k1, OpenSSL, blst, mcl)
    exe.addIncludePath(.{ .cwd_relative = crypto_include });
    exe.linkSystemLibrary("secp256k1");
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("m");
    exe.addObjectFile(.{ .cwd_relative = libblst_path });
    addMcl(exe, is_linux, libmcl_path);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_test_block_step = b.step("run-test-block", "Run against test/vectors/test_block*.json");
    const run_test_block_cmd = b.addRunArtifact(exe);
    run_test_block_cmd.step.dependOn(b.getInstallStep());
    run_test_block_cmd.addArgs(&.{
        "--json",
        "test/vectors/stateless/test_block.json",
        "test/vectors/stateless/test_block_witness.json",
    });
    run_test_block_step.dependOn(&run_test_block_cmd.step);

    // gen_example: generate examples/block.json and examples/witness.json
    const gen_example_exe = b.addExecutable(.{
        .name = "gen_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "primitives", .module = primitives },
                .{ .name = "mpt", .module = mpt_mod },
            },
        }),
    });
    b.installArtifact(gen_example_exe);

    const gen_example_step = b.step("gen-example", "Generate examples/block.json and examples/witness.json");
    const run_gen_example = b.addRunArtifact(gen_example_exe);
    gen_example_step.dependOn(&run_gen_example.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    mod_tests.linkLibC();
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    exe_tests.linkLibC();
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // MPT integration tests in src/mpt/test.zig
    const mpt_test_mod = b.createModule(.{
        .root_source_file = b.path("src/mpt/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    mpt_test_mod.addImport("primitives", primitives);
    mpt_test_mod.addImport("mpt", mpt_mod);
    mpt_test_mod.addImport("input", input_mod);
    const mpt_tests = b.addTest(.{ .root_module = mpt_test_mod });
    mpt_tests.linkLibC();
    const run_mpt_tests = b.addRunArtifact(mpt_tests);

    // WitnessDatabase integration tests in src/db/test.zig
    const db_test_mod = b.createModule(.{
        .root_source_file = b.path("src/db/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    db_test_mod.addImport("primitives", primitives);
    db_test_mod.addImport("state", state);
    db_test_mod.addImport("bytecode", bytecode);
    db_test_mod.addImport("mpt", mpt_mod);
    db_test_mod.addImport("input", input_mod);
    db_test_mod.addImport("db", db_mod);
    const db_tests = b.addTest(.{ .root_module = db_test_mod });
    db_tests.linkLibC();
    const run_db_tests = b.addRunArtifact(db_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_mpt_tests.step);
    test_step.dependOn(&run_db_tests.step);

    // ---------------------------------------------------------------------------
    // t8n — Ethereum State Transition Tool (execution-spec-tests compatible)
    //
    // Implements the geth evm t8n interface:
    //   t8n --input.alloc A --input.env E --input.txs T --state.fork F \
    //       --output.alloc out/alloc.json --output.result out/result.json
    //
    // Uses zevm for EVM execution.
    // Links secp256k1 for transaction signing/recovery, OpenSSL for precompiles.
    // ---------------------------------------------------------------------------

    // ── Named executor modules for t8n / spec-test ───────────────────────────────
    // These expose executor/ source files as named imports so that t8n and spec-test
    // can import them without crossing module-root boundaries.

    // executor_allocator — injectable allocator for executor internals.
    // Default: std.heap.c_allocator (suitable for native builds).
    // zkVM builds override this by wiring their own module:
    //   executor_transition_mod.addImport("executor_allocator", your_alloc_module)
    const executor_allocator_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/executor_allocator.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // executor_types — canonical EVM type definitions; no external deps
    const executor_types_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    // db_mod needs executor_types for BlockHashEntry (defined after db_mod creation)
    db_mod.addImport("executor_types", executor_types_mod);
    db_mod.addImport("database", database);

    // executor_rlp_encode — RLP encoding primitives; shared by transition and output
    const executor_rlp_encode_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/rlp_encode.zig"),
        .target = target,
        .optimize = optimize,
    });

    // executor_exceptions — canonical TransactionException / BlockException enum types
    const executor_exceptions_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/exceptions.zig"),
        .target = target,
        .optimize = optimize,
    });

    // executor_bal — EIP-7928 block access list RLP decoder
    const executor_bal_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/bal.zig"),
        .target = target,
        .optimize = optimize,
    });
    executor_bal_mod.addImport("primitives", primitives);
    executor_bal_mod.addImport("mpt", mpt_mod);
    executor_bal_mod.addImport("executor_rlp_encode", executor_rlp_encode_mod);

    // executor_block_validation — block header validation (excess_blob_gas, etc.)
    const executor_block_validation_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/block_validation.zig"),
        .target = target,
        .optimize = optimize,
    });
    executor_block_validation_mod.addImport("executor_types", executor_types_mod);
    executor_block_validation_mod.addImport("primitives", primitives);
    executor_block_validation_mod.addImport("executor_bal", executor_bal_mod);

    // native_executor_transition — transition logic using crypto-enabled local zevm
    const native_executor_transition_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/transition.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_executor_transition_mod.addImport("executor_types", executor_types_mod);
    native_executor_transition_mod.addImport("executor_rlp_encode", executor_rlp_encode_mod);
    native_executor_transition_mod.addImport("executor_exceptions", executor_exceptions_mod);
    native_executor_transition_mod.addImport("primitives", primitives);
    native_executor_transition_mod.addImport("state", state);
    native_executor_transition_mod.addImport("bytecode", bytecode);
    native_executor_transition_mod.addImport("database", database);
    native_executor_transition_mod.addImport("context", context);
    native_executor_transition_mod.addImport("handler", handler);
    native_executor_transition_mod.addImport("precompile", precompile);
    // secp256k1_wrapper — default: standalone C wrapper for native tx signing.
    // Independent of zevm's precompile module graph to avoid file-ownership
    // conflicts.  Override in zkVM builds with an accelerated implementation:
    //   transition_mod.addImport("secp256k1_wrapper", your_zisk_module)
    const secp256k1_impl_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/secp256k1_impl.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_executor_transition_mod.addImport("secp256k1_wrapper", secp256k1_impl_mod);
    native_executor_transition_mod.addImport("executor_allocator", executor_allocator_mod);
    native_executor_transition_mod.addImport("executor_bal", executor_bal_mod);

    // native_executor_output — trie computations; uses executor_transition for type consistency
    const native_executor_output_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/output.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_executor_output_mod.addImport("executor_types", executor_types_mod);
    native_executor_output_mod.addImport("executor_rlp_encode", executor_rlp_encode_mod);
    native_executor_output_mod.addImport("mpt_builder", mpt_builder_mod);
    native_executor_output_mod.addImport("mpt", mpt_mod);

    // hardfork — single source of truth for fork names, SpecId mapping,
    // mainnet activation schedule, and block rewards (declared early; used widely)
    const hardfork_mod = b.createModule(.{
        .root_source_file = b.path("src/hardfork.zig"),
        .target = target,
        .optimize = optimize,
    });
    hardfork_mod.addImport("primitives", primitives);

    // native_executor_tx_decode — raw RLP tx bytes → TxInput, or input.Transaction → TxInput
    const native_executor_tx_decode_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/tx_decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_executor_tx_decode_mod.addImport("executor_types", executor_types_mod);
    native_executor_tx_decode_mod.addImport("input", input_mod);
    native_executor_tx_decode_mod.addImport("rlp_decode", rlp_decode_mod);

    // Deferred: wire executor_output into transition (output_mod created after transition_mod)
    native_executor_transition_mod.addImport("executor_output", native_executor_output_mod);

    // Wire named executor sub-modules into executor_mod (deferred — modules created above)
    executor_mod.addImport("executor_types", executor_types_mod);
    executor_mod.addImport("executor_rlp_encode", executor_rlp_encode_mod);
    executor_mod.addImport("executor_transition", native_executor_transition_mod);
    executor_mod.addImport("executor_output", native_executor_output_mod);
    executor_mod.addImport("hardfork", hardfork_mod);
    executor_mod.addImport("executor_tx_decode", native_executor_tx_decode_mod);
    executor_mod.addImport("rlp_decode", rlp_decode_mod);
    executor_mod.addImport("executor_block_validation", executor_block_validation_mod);
    executor_mod.addImport("executor_bal", executor_bal_mod);

    // t8n_input — t8n JSON parsing + re-exports executor types; used by spec-test-runner
    const t8n_input_mod = b.createModule(.{
        .root_source_file = b.path("src/t8n/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    t8n_input_mod.addImport("executor_types", executor_types_mod);

    const t8n_exe = b.addExecutable(.{
        .name = "t8n",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/t8n/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "primitives", .module = primitives },
                .{ .name = "state", .module = state },
                .{ .name = "bytecode", .module = bytecode },
                .{ .name = "database", .module = database },
                .{ .name = "context", .module = context },
                .{ .name = "handler", .module = handler },
                .{ .name = "precompile", .module = precompile },
                .{ .name = "mpt_builder", .module = mpt_builder_mod },
                .{ .name = "executor_types", .module = executor_types_mod },
                .{ .name = "executor_transition", .module = native_executor_transition_mod },
                .{ .name = "executor_output", .module = native_executor_output_mod },
                .{ .name = "hardfork", .module = hardfork_mod },
            },
        }),
    });
    // secp256k1_recovery.h and secp256k1.h are in the Homebrew include path.
    // OpenSSL headers and libraries are also required by zevm_local's precompile module.
    t8n_exe.addIncludePath(.{ .cwd_relative = crypto_include });
    t8n_exe.linkSystemLibrary("secp256k1");
    t8n_exe.linkSystemLibrary("ssl");
    t8n_exe.linkSystemLibrary("crypto");
    t8n_exe.linkSystemLibrary("c");
    t8n_exe.linkSystemLibrary("m");
    t8n_exe.addObjectFile(.{ .cwd_relative = libblst_path });
    addMcl(t8n_exe, is_linux, libmcl_path);

    b.installArtifact(t8n_exe);

    // zig build t8n [-- --input.alloc ... --state.fork Cancun ...]
    const run_t8n_step = b.step("t8n", "Run the t8n state transition tool");
    const run_t8n_cmd = b.addRunArtifact(t8n_exe);
    run_t8n_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_t8n_cmd.addArgs(args);
    run_t8n_step.dependOn(&run_t8n_cmd.step);

    // ---------------------------------------------------------------------------
    // spec-test-runner — Native Zig runner for execution-spec-tests state fixtures
    //
    // Reads fixture JSONs from test/fixtures/fixtures/state_tests, builds TxInput
    // from indexed transaction fields + transaction.sender (no ECDSA), calls
    // transition() directly, and compares stateRoot + logsHash to expected values.
    //
    // Usage: zig build state-tests [-- --fork Cancun --file path/to/fixture.json -x]
    // Fixtures dir: spec-tests/fixtures/state_tests (download with: zig build fetch-fixtures)
    // ---------------------------------------------------------------------------
    const spec_test_exe = b.addExecutable(.{
        .name = "spec-test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spec_test/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "primitives", .module = primitives },
                .{ .name = "state", .module = state },
                .{ .name = "bytecode", .module = bytecode },
                .{ .name = "database", .module = database },
                .{ .name = "context", .module = context },
                .{ .name = "handler", .module = handler },
                .{ .name = "precompile", .module = precompile },
                .{ .name = "mpt_builder", .module = mpt_builder_mod },
                .{ .name = "executor_types", .module = executor_types_mod },
                .{ .name = "executor_transition", .module = native_executor_transition_mod },
                .{ .name = "executor_output", .module = native_executor_output_mod },
                .{ .name = "t8n_input", .module = t8n_input_mod },
                .{ .name = "hardfork", .module = hardfork_mod },
            },
        }),
    });
    spec_test_exe.addIncludePath(.{ .cwd_relative = crypto_include });
    spec_test_exe.linkSystemLibrary("secp256k1");
    spec_test_exe.linkSystemLibrary("ssl");
    spec_test_exe.linkSystemLibrary("crypto");
    spec_test_exe.linkSystemLibrary("c");
    spec_test_exe.linkSystemLibrary("m");
    spec_test_exe.addObjectFile(.{ .cwd_relative = libblst_path });
    addMcl(spec_test_exe, is_linux, libmcl_path);

    b.installArtifact(spec_test_exe);

    const run_state_tests_step = b.step("state-tests", "Run execution-spec-tests state fixtures");
    const run_spec_tests_cmd = b.addRunArtifact(spec_test_exe);
    run_spec_tests_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_spec_tests_cmd.addArgs(args);
    run_state_tests_step.dependOn(&run_spec_tests_cmd.step);

    // ---------------------------------------------------------------------------
    // blockchain-test-runner — Ethereum blockchain test fixture runner
    //
    // Reads blockchain_tests JSON fixtures, executes each single-block test,
    // and validates post_state_root, receipts_root, and lastblockhash.
    //
    // Usage: zig build blockchain-tests [-- --fork Cancun --file path/to/fixture.json -x -q]
    // Fixtures dir: spec-tests/fixtures/blockchain_tests
    // ---------------------------------------------------------------------------

    // blockchain_test runner module
    const blockchain_test_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/blockchain_test/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    blockchain_test_runner_mod.addImport("executor_types", executor_types_mod);
    blockchain_test_runner_mod.addImport("executor_exceptions", executor_exceptions_mod);
    blockchain_test_runner_mod.addImport("executor", executor_mod);
    blockchain_test_runner_mod.addImport("executor_tx_decode", native_executor_tx_decode_mod);
    blockchain_test_runner_mod.addImport("mpt", mpt_mod);
    blockchain_test_runner_mod.addImport("hardfork", hardfork_mod);
    const bc_test_exe = b.addExecutable(.{
        .name = "blockchain-test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/blockchain_test/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "primitives", .module = primitives },
                .{ .name = "state", .module = state },
                .{ .name = "bytecode", .module = bytecode },
                .{ .name = "database", .module = database },
                .{ .name = "context", .module = context },
                .{ .name = "handler", .module = handler },
                .{ .name = "precompile", .module = precompile },
                .{ .name = "mpt_builder", .module = mpt_builder_mod },
                .{ .name = "executor_types", .module = executor_types_mod },
                .{ .name = "executor_transition", .module = native_executor_transition_mod },
                .{ .name = "executor_output", .module = native_executor_output_mod },
                .{ .name = "runner.zig", .module = blockchain_test_runner_mod },
            },
        }),
    });
    bc_test_exe.addIncludePath(.{ .cwd_relative = crypto_include });
    bc_test_exe.linkSystemLibrary("secp256k1");
    bc_test_exe.linkSystemLibrary("ssl");
    bc_test_exe.linkSystemLibrary("crypto");
    bc_test_exe.linkSystemLibrary("c");
    bc_test_exe.linkSystemLibrary("m");
    bc_test_exe.addObjectFile(.{ .cwd_relative = libblst_path });
    addMcl(bc_test_exe, is_linux, libmcl_path);

    b.installArtifact(bc_test_exe);

    const run_bc_tests_step = b.step("blockchain-tests", "Run Ethereum blockchain test fixtures");
    const run_bc_tests_cmd = b.addRunArtifact(bc_test_exe);
    run_bc_tests_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_bc_tests_cmd.addArgs(args);
    run_bc_tests_step.dependOn(&run_bc_tests_cmd.step);

    // ---------------------------------------------------------------------------
    // all-spec-tests-runner — combined state + blockchain spec-test runner
    //
    // Spawns spec-test-runner and blockchain-test-runner as subprocesses and
    // prints a unified summary across both suites.
    //
    // Usage: zig build spec-tests [-- --fork Cancun -q]
    // ---------------------------------------------------------------------------
    const all_spec_exe = b.addExecutable(.{
        .name = "all-spec-tests-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/all_spec_tests/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(all_spec_exe);

    const run_spec_tests_step = b.step("spec-tests", "Run all spec-tests: state + blockchain");
    const run_all_spec_cmd = b.addRunArtifact(all_spec_exe);
    run_all_spec_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_all_spec_cmd.addArgs(args);
    run_spec_tests_step.dependOn(&run_all_spec_cmd.step);

    // ---------------------------------------------------------------------------
    // hive-rlp — Hive consume-rlp execution client
    //
    // Reads /genesis.json and /blocks/*.rlp at startup, executes the chain,
    // and serves eth_getBlockByNumber on :8545 for Hive validation.
    //
    // Usage: zig build hive-rlp
    // ---------------------------------------------------------------------------
    const hive_rlp_exe = b.addExecutable(.{
        .name = "hive-rlp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hive/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "primitives", .module = primitives },
                .{ .name = "state", .module = state },
                .{ .name = "bytecode", .module = bytecode },
                .{ .name = "database", .module = database },
                .{ .name = "context", .module = context },
                .{ .name = "handler", .module = handler },
                .{ .name = "precompile", .module = precompile },
                .{ .name = "mpt_builder", .module = mpt_builder_mod },
                .{ .name = "mpt", .module = mpt_mod },
                .{ .name = "executor_types", .module = executor_types_mod },
                .{ .name = "executor_rlp_encode", .module = executor_rlp_encode_mod },
                .{ .name = "executor_output", .module = native_executor_output_mod },
                .{ .name = "hardfork", .module = hardfork_mod },
                .{ .name = "executor_tx_decode", .module = native_executor_tx_decode_mod },
                .{ .name = "executor", .module = executor_mod },
            },
        }),
    });
    hive_rlp_exe.addIncludePath(.{ .cwd_relative = crypto_include });
    hive_rlp_exe.linkSystemLibrary("secp256k1");
    hive_rlp_exe.linkSystemLibrary("ssl");
    hive_rlp_exe.linkSystemLibrary("crypto");
    hive_rlp_exe.linkSystemLibrary("c");
    hive_rlp_exe.linkSystemLibrary("m");
    hive_rlp_exe.addObjectFile(.{ .cwd_relative = libblst_path });
    addMcl(hive_rlp_exe, is_linux, libmcl_path);

    b.installArtifact(hive_rlp_exe);

    const run_hive_rlp_step = b.step("hive-rlp", "Build and install the Hive consume-rlp client");
    run_hive_rlp_step.dependOn(b.getInstallStep());

    // zig build fetch-fixtures — download execution-spec-tests bal@v5.5.1 fixtures
    const fetch_fixtures_step = b.step("fetch-fixtures", "Download execution-spec-tests fixtures");
    const fetch_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        "rm -rf spec-tests/fixtures && " ++
            "mkdir -p spec-tests/fixtures && " ++
            "echo 'Downloading execution-spec-tests bal@v5.5.1 fixtures...' && " ++
            "curl -fL " ++
            "https://github.com/ethereum/execution-spec-tests/releases/download/bal%40v5.5.1/fixtures_bal.tar.gz " ++
            "| tar xz --strip-components=1 -C spec-tests/fixtures/ && " ++
            "echo 'Done. Fixtures extracted to spec-tests/fixtures/'",
    });
    fetch_fixtures_step.dependOn(&fetch_cmd.step);

    // ---------------------------------------------------------------------------
    // zkevm-blockchain-test-runner — runner for zkevm execution-spec-tests fixtures
    //
    // Decodes SSZ statelessInputBytes, runs stateless execution, and asserts the
    // 41-byte SSZ output matches statelessOutputBytes.
    //
    // Usage: zig build zkevm-tests [-- --fixtures DIR -q -x]
    // Fixtures dir: spec-tests/fixtures/zkevm/blockchain_tests
    //   (download with: zig build fetch-zkevm-fixtures)
    // ---------------------------------------------------------------------------

    // ssz_decode — SSZ input decoder (src/stateless/ssz.zig)
    const ssz_decode_mod = b.createModule(.{
        .root_source_file = b.path("src/stateless/ssz.zig"),
        .target = target,
        .optimize = optimize,
    });
    ssz_decode_mod.addImport("input", input_mod);
    ssz_decode_mod.addImport("rlp_decode", rlp_decode_mod);

    // ---------------------------------------------------------------------------
    // ere-server — standalone Twirp HTTP/1.1 server for the ZkvmService interface
    //
    // Receives SSZ-encoded StatelessInput via protobuf field 1, executes the block
    // using the stateless executor, and returns the result as JSON public_values.
    //
    // Usage: ere-server [port]   (default port 50051)
    // ---------------------------------------------------------------------------
    const ere_server_exe = b.addExecutable(.{
        .name = "ere-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ere_server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "executor", .module = executor_mod },
                .{ .name = "ssz_decode", .module = ssz_decode_mod },
                .{ .name = "main_allocator", .module = main_allocator_mod },
            },
        }),
    });
    ere_server_exe.addIncludePath(.{ .cwd_relative = crypto_include });
    ere_server_exe.linkSystemLibrary("secp256k1");
    ere_server_exe.linkSystemLibrary("ssl");
    ere_server_exe.linkSystemLibrary("crypto");
    ere_server_exe.linkSystemLibrary("c");
    ere_server_exe.linkSystemLibrary("m");
    ere_server_exe.addObjectFile(.{ .cwd_relative = libblst_path });
    addMcl(ere_server_exe, is_linux, libmcl_path);
    b.installArtifact(ere_server_exe);
    const ere_server_step = b.step("ere-server", "Build and install the ere-server");
    ere_server_step.dependOn(b.getInstallStep());

    // ssz_output — SSZ output serializer (src/stateless/ssz_output.zig)
    const ssz_output_mod = b.createModule(.{
        .root_source_file = b.path("src/stateless/ssz_output.zig"),
        .target = target,
        .optimize = optimize,
    });
    ssz_output_mod.addImport("input", input_mod);

    const zkevm_bc_test_exe = b.addExecutable(.{
        .name = "zkevm-blockchain-test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zkevm_blockchain_test/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "executor", .module = executor_mod },
                .{ .name = "ssz_decode", .module = ssz_decode_mod },
                .{ .name = "ssz_output", .module = ssz_output_mod },
                .{ .name = "executor_exceptions", .module = executor_exceptions_mod },
            },
        }),
    });
    zkevm_bc_test_exe.addIncludePath(.{ .cwd_relative = crypto_include });
    zkevm_bc_test_exe.linkSystemLibrary("secp256k1");
    zkevm_bc_test_exe.linkSystemLibrary("ssl");
    zkevm_bc_test_exe.linkSystemLibrary("crypto");
    zkevm_bc_test_exe.linkSystemLibrary("c");
    zkevm_bc_test_exe.linkSystemLibrary("m");
    zkevm_bc_test_exe.addObjectFile(.{ .cwd_relative = libblst_path });
    addMcl(zkevm_bc_test_exe, is_linux, libmcl_path);

    b.installArtifact(zkevm_bc_test_exe);

    const run_zkevm_tests_step = b.step("zkevm-tests", "Run zkevm blockchain test fixtures");
    const run_zkevm_tests_cmd = b.addRunArtifact(zkevm_bc_test_exe);
    run_zkevm_tests_cmd.step.dependOn(b.getInstallStep());
    run_zkevm_tests_cmd.addArgs(&.{ "--fixtures", "spec-tests/fixtures/zkevm/blockchain_tests" });
    if (b.args) |extra_args| run_zkevm_tests_cmd.addArgs(extra_args);
    run_zkevm_tests_step.dependOn(&run_zkevm_tests_cmd.step);

    // zig build fetch-zkevm-fixtures — download zkevm@v0.3.2 fixtures
    const fetch_zkevm_step = b.step("fetch-zkevm-fixtures", "Download zkevm@v0.3.2 execution-spec-tests fixtures");
    const fetch_zkevm_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        "mkdir -p spec-tests/fixtures/zkevm && " ++
            "echo 'Downloading zkevm@v0.3.2 fixtures...' && " ++
            "curl -fL " ++
            "https://github.com/ethereum/execution-spec-tests/releases/download/zkevm%40v0.3.2/fixtures_zkevm.tar.gz " ++
            "| tar xz --strip-components=1 -C spec-tests/fixtures/zkevm/ && " ++
            "echo 'Done. Fixtures extracted to spec-tests/fixtures/zkevm/'",
    });
    fetch_zkevm_step.dependOn(&fetch_zkevm_cmd.step);
}
