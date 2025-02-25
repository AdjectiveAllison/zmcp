const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Create the library
    const lib = b.addStaticLibrary(.{
        .name = "zmcp",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/zmcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Create the module that examples can import
    const zmcp_module = b.addModule("zmcp", .{
        .root_source_file = b.path("src/zmcp.zig"),
    });

    // Build the echo example
    const echo_example = b.addExecutable(.{
        .name = "echo-example",
        .root_source_file = b.path("examples/echo.zig"),
        .target = target,
        .optimize = optimize,
    });
    echo_example.root_module.addImport("zmcp", zmcp_module);

    // Install the echo example
    const echo_install = b.addInstallArtifact(echo_example, .{});

    // Add a build-only step for the echo example
    const build_echo_step = b.step("build-echo", "Build the echo example without running");
    build_echo_step.dependOn(&echo_install.step);

    // Add a run step for the echo example
    const run_echo_cmd = b.addRunArtifact(echo_example);
    if (b.args) |args| {
        run_echo_cmd.addArgs(args);
    }
    const run_echo_step = b.step("run-echo", "Run the echo example");
    run_echo_step.dependOn(&run_echo_cmd.step);

    // Build the client example
    const client_example = b.addExecutable(.{
        .name = "client-example",
        .root_source_file = b.path("examples/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_example.root_module.addImport("zmcp", zmcp_module);

    // Install the client example
    const client_install = b.addInstallArtifact(client_example, .{});

    // Add a build-only step for the client example
    const build_client_step = b.step("build-client", "Build the client example without running");
    build_client_step.dependOn(&client_install.step);

    // Add a run step for the client example
    const run_client_cmd = b.addRunArtifact(client_example);
    if (b.args) |args| {
        run_client_cmd.addArgs(args);
    }
    const run_client_step = b.step("run-client", "Run the client example");
    run_client_step.dependOn(&run_client_cmd.step);

    // Build the test client (simple version)
    const test_client = b.addExecutable(.{
        .name = "test-client",
        .root_source_file = b.path("examples/test_client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install the test client
    const test_client_install = b.addInstallArtifact(test_client, .{});

    // Add a build-only step for the test client
    const build_test_client_step = b.step("build-test-client", "Build the simple test client");
    build_test_client_step.dependOn(&test_client_install.step);

    // Add a run step for the test client
    const run_test_client_cmd = b.addRunArtifact(test_client);
    if (b.args) |args| {
        run_test_client_cmd.addArgs(args);
    }
    const run_test_client_step = b.step("run-test-client", "Run the simple test client");
    run_test_client_step.dependOn(&run_test_client_cmd.step);

    // Add a build-all-examples step
    const build_examples_step = b.step("build-examples", "Build all examples without running");
    build_examples_step.dependOn(build_echo_step);
    build_examples_step.dependOn(build_client_step);
    build_examples_step.dependOn(build_test_client_step);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/zmcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
