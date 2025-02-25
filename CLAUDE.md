# ZMCP Project Guidelines

## Build Commands
- Build library: `zig build`
- Build with optimization: `zig build -Doptimize=ReleaseFast|ReleaseSafe|ReleaseSmall`
- Test all units: `zig build test`
- Run single test: `zig test src/lib/tool.test.zig`
- Test specific case: `zig test src/lib/tool.test.zig -test-filter "Tool validates handler parameters"`
- Run examples: `zig build run-echo` or `zig build run-client`

## Code Style
- Naming: snake_case for variables/functions, PascalCase for types/structs
- Imports: std first, then local modules, grouped at top of file
- Error handling: use try/catch with descriptive error names and explicit propagation
- Memory: explicit allocator passing, defer for cleanup, deinit methods for resources
- Types: use nullable types for optional fields with defaults
- Documentation: comment public API and complex logic
- Tests: descriptive "X does Y" test names, cover edge cases

## Known Issues
- tool.test.zig execution not integrated with main test step
- Compile-time validation gaps for handler parameter checking
- Fixed 4KB buffer size limitation for input in server.zig
- Schema generation uses unsafe error handling