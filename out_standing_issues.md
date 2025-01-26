tool.test.zig doesn't get called. Testing for tools need to be improved. It's pretty bad currently.

Compile-Time Validation Gaps
Problem: Invalid handler test passes when it should fail
Location: tool.test.zig and tool.zig
Fix: Strengthen type checks in wrapFunction:
```zig
comptime {
  if (!@hasField(ParamType, "allocator")) @compileError(...);
}
```

Fixed Buffer Size for Input
Problem: 4KB buffer truncates large requests
Location: server.zig start()
Solution: Use streaming JSON parser with dynamic buffers

Struct Default Value Handling
Problem: Incorrect pointer casting for default values
Location: tool.zig convertFromJson()
Fix: Use @fieldParentPtr and validate types:
```zig
const default = @fieldParentPtr(field.type, default_ptr).*;
```

Idk if this one is actually an issue or if comptime validation should be enough to prevent it, but adding it just in case to reflect on later:
Unsafe Error Handling in Schema Generation
Problem: catch unreachable on allocation errors
Location: tool.zig generateSchema()
Fix: Propagate errors or use error-aware allocator