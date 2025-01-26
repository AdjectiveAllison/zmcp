# zmcp - a Zig MCP Library

A lightweight Zig implementation of the [Model Context Protocol](https://spec.modelcontextprotocol.io/) (MCP). ZMCP enables seamless integration between LLM applications and external tools through compile-time validated interfaces.

## Features

- **Type-Safe Tools**: Struct-based parameters with compile-time validation
- **Automatic Resource Management**: Allocator injection for heap-using tools
- **Error Conversion**: Zig errors automatically converted to MCP error responses
- **Transport Layer**: Current support for stdio transport (HTTP+SSE planned)
- **MCP Features**:
  - ✅ Tools API with full schema generation
  - ✅ Basic logging support
  - ✅ Progress tracking
  - ⏳ Resources API (planned)
  - ⏳ Prompts API (planned)


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

## Quick Start

```zig
const EchoParams = struct {
    allocator: std.mem.Allocator, // Auto-injected by server
    message: []const u8,
    repeat: u32 = 1 // Default value
};

fn echoFn(params: EchoParams) ![]const u8 {
    // ... implementation using params.allocator
}

const echo_tool = zmcp.Tool(
    "echo",
    "Echo with repetition",
    echoFn // Struct-based handler
);
```

## Structured Parameters

Tools must use a struct parameter containing:
- An optional `allocator` field (auto-injected)
- Typed parameters with validation
- Optional fields with default values
- struct keys turn into names for the tool call parameters

Example parameter struct:
```zig
const ProcessArgs = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    iterations: u32 = 10,
    verbose: ?bool = null
};
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
