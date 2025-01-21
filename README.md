# zmcp - a Zig MCP Library

A lightweight Zig implementation of the [Model Context Protocol](https://spec.modelcontextprotocol.io/) (MCP). ZMCP enables seamless integration between LLM applications and external tools through compile-time validated interfaces.

## Features

- **Zero-cost Abstractions**: Compile-time validation of tool interfaces with no runtime overhead
- **Smart Type Conversion**: Automatic translation between Zig types and JSON 
  - Supports basic types (strings, integers, floats, booleans)
  - Handles optionals and arrays
  - Generates JSON schemas at compile time
- **Transport Layer**: Current support for stdio transport (HTTP+SSE planned)
- **MCP Features**:
  - ✅ Tools API with full schema generation
  - ✅ Basic logging support
  - ✅ Progress tracking
  - ⏳ Resources API (planned)
  - ⏳ Prompts API (planned)

## Quick Start

```zig
const std = @import("std");
const zmcp = @import("zmcp");

// Define a simple tool function
fn echoFn(message: []const u8) ![]const u8 {
    return message;
}

// Create an MCP tool with compile-time validation
const echo_tool = zmcp.Tool(
    "echo",
    "Echo back a message",
    echoFn,
);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try zmcp.Server.init(allocator, "Example Server", "1.0.0");
    defer server.deinit();

    try server.addTool(echo_tool);
    try server.start();
}
```

## Installation

1. Add zmcp as a dependency using `zig fetch`:

```sh
# Latest version
zig fetch --save git+https://github.com/AdjectiveAllison/zmcp.git#main
```

2. Add zmcp as a module in your `build.zig`:

```zig
const zmcp_dep = b.dependency("zmcp", .{
    .target = target,
    .optimize = optimize,
});
const zmcp = zmcp_dep.module("zmcp");

// Add to your executable
exe.root_module.addImport("zmcp", zmcp);
```

## Type System

ZMCP automatically handles conversion between Zig types and JSON values:

```zig
// Supported types for tool parameters and returns:
const BasicTypes = union(enum) {
    string: []const u8,      // JSON string
    integer: i64,           // JSON number (integer)
    float: f64,            // JSON number (float)
    boolean: bool,         // JSON boolean
    optional: ?[]const u8,  // JSON null | type
    array: []const u8,     // JSON array
};

// Structs are automatically converted to JSON objects
const Config = struct {
    name: []const u8,
    count: i64,
    enabled: ?bool,
};

fn configTool(config: Config) !void {
    // Fields are automatically validated and converted
}

const tool = zmcp.Tool("config", "Update config", configTool);
```

## Current Limitations

- Only stdio transport supported (HTTP+SSE planned)
- Resources and Prompts APIs not yet implemented
- Limited to JSON-compatible Zig types
- No support for custom transports

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
