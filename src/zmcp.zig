const std = @import("std");
const protocol = @import("lib/protocol.zig");
const server = @import("lib/server.zig");
const tool = @import("lib/tool.zig");
const types = @import("lib/types.zig");

// Stage 1: Base Library Implementation
// 1.1 Core Types

// Create Tool struct with validation
// Define internal ProcessedTool type for MCP representation
// Create server type with tool registration

// 1.2 Type Conversion

// Implement JSON <-> Zig type conversion utilities
// Generate JSON schemas from Zig types
// Validate supported parameter types

// 1.3 Protocol Implementation

// Move existing JSON-RPC handling to library
// Implement tool registration and lookup
// Add stdio transport support
// Add basic error handling

// 1.4 Testing Infrastructure

// Unit tests for type conversion
// Integration tests with example tools
// Error case testing

// We also need to clean up all the existing code to be ready for the new library format.

pub const Server = server.Server;
pub const Tool = tool.Tool;
pub const Value = protocol.Value;

test {
    std.testing.refAllDecls(@This());
}
