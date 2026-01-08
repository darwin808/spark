# Spark Performance Roadmap

Goal: Fastest web framework benchmarked against Tokio/Axum (Rust), GoFiber (Go), Drogon (C++), uWebSockets (C++).

## Current State

### Completed
- io_uring (Linux) / kqueue (macOS) for async I/O
- Zero-copy HTTP parsing (slices into buffer)
- Connection and buffer pooling
- Arena allocation with O(1) reset
- Security hardening (request limits, header limits, DoS protection)
- Benchmark infrastructure (plaintext, json, db, queries)
- Comprehensive documentation

### What's Missing for Top-tier Performance
- Single-threaded only
- No SIMD parsing
- Basic io_uring usage (no advanced features)
- No HTTP pipelining

---

## Phase 1: Measurement Infrastructure ✅

Can't optimize what you can't measure.

### 1.1 Benchmark Suite ✅
- [x] Add `benchmarks/` directory with standardized tests
- [x] Plaintext response (`/plaintext` - "Hello, World!")
- [x] JSON serialization (`/json` - `{"message":"Hello, World!"}`)
- [x] Single query (`/db` - stubbed)
- [x] Multiple queries (`/queries?n=20` - stubbed)
- [x] Match TechEmpower benchmark formats

### 1.2 Benchmark Tooling (Partial)
- [ ] Scripts to run wrk/wrk2/bombardier against Spark
- [ ] Comparison scripts against competitors (Axum, GoFiber, Drogon)
- [ ] Latency distribution tracking (p50, p99, p99.9)
- [ ] Throughput (req/sec) at various concurrency levels

### 1.3 Profiling Integration
- [ ] perf integration for Linux
- [ ] Instruments integration for macOS
- [ ] Flamegraph generation scripts

---

## Phase 2: Developer Experience ✅

Make development fast and enjoyable.

### 2.1 Hot Reload ✅
- [x] File watcher for source changes (kqueue on macOS, inotify on Linux)
- [x] Automatic recompilation on change
- [x] Graceful server restart (SIGTERM with drain timeout)
- [x] Sub-second reload times
- [x] Run with: `zig build dev -- run-hello_world`
- [ ] Optional: WebSocket injection for browser auto-refresh

### 2.2 Better Error Messages
- [ ] Colored terminal output for errors
- [ ] Stack traces with source locations
- [ ] Suggested fixes for common errors
- [ ] Request/response debugging mode

### 2.3 CLI Tooling
- [ ] `spark new <project>` - scaffold new project
- [ ] `spark dev` - run with hot reload
- [ ] `spark build` - production build
- [ ] `spark routes` - list all registered routes

---

## Phase 3: Multi-threading ✅

Single-threaded is the biggest current bottleneck.

### 3.1 Thread-per-core Model ✅
- [x] SO_REUSEPORT for multiple listeners (kernel load-balances accepts)
- [x] One event loop per core (no cross-thread communication)
- [x] Thread-local connection pools
- [x] Thread-local buffer pools
- [x] Auto-detect CPU count (configurable via `num_workers`)

### 3.2 Work Stealing (Optional)
- [ ] Lock-free work queue for load balancing
- [ ] Only if thread-per-core shows imbalance

---

## Phase 4: io_uring Optimization (Linux) ✅

io_uring has features we're not using.

### 4.1 Multishot Accept ✅
- [x] IORING_ACCEPT_MULTISHOT - single SQE for multiple accepts
- [x] Reduces submission overhead for accept-heavy workloads
- [x] Configurable via `io_uring_multishot_accept` option

### 4.2 Provided Buffers (Buffer Rings)
- [ ] IORING_OP_PROVIDE_BUFFERS - kernel-managed buffer pool
- [ ] Eliminates user-space buffer management overhead
- [ ] Automatic buffer selection by kernel

### 4.3 Registered Buffers & Files ✅
- [x] IORING_REGISTER_BUFFERS - pin buffers in kernel
- [x] IORING_REGISTER_FILES - avoid fd lookup per operation
- [x] Reduces per-operation overhead
- [x] APIs added: `registerBuffers`, `registerFiles`, `queueReadFixed`, `queueWriteFixed`

### 4.4 Submission Batching ✅
- [x] Batch multiple SQEs before submit
- [x] Single syscall for multiple operations
- [x] `reapCompletions()` for batch completion handling

### 4.5 SQPOLL Mode ✅
- [x] IORING_SETUP_SQPOLL - kernel polling thread
- [x] Zero syscalls for submissions
- [x] Configurable via `io_uring_sqpoll` option
- [x] Graceful fallback when permissions insufficient

---

## Phase 5: Parser Optimization

HTTP parsing is CPU-bound. SIMD helps.

### 5.1 SIMD HTTP Parsing
- [ ] Use `@Vector` for parallel byte scanning
- [ ] Find delimiters (space, CRLF, colon) in 16/32 bytes at once
- [ ] Reference: picohttpparser, llhttp

### 5.2 Method Parsing Optimization
- [ ] Compare first 4/8 bytes as integer (already partially done)
- [ ] Jump table for method dispatch

### 5.3 Header Parsing
- [ ] SIMD search for `\r\n`
- [ ] Fast case-insensitive comparison for common headers
- [ ] Pre-hash common header names

### 5.4 URL Parsing
- [ ] SIMD search for `?`, `#`, space
- [ ] Avoid per-character branching

---

## Phase 6: Memory Optimization

Cache misses are expensive.

### 6.1 Hot/Cold Data Separation
- [ ] Frequently accessed fields in first cache line (64 bytes)
- [ ] Connection struct layout optimization
- [ ] Benchmark with `perf stat` cache metrics

### 6.2 Arena Improvements
- [ ] Bump allocator (simpler than current arena)
- [ ] Pre-warm arenas to avoid page faults
- [ ] Huge pages for buffer pools (2MB pages)

### 6.3 Object Pooling
- [ ] Pool parsed request objects
- [ ] Pool response builders
- [ ] Avoid allocation in hot path entirely

---

## Phase 7: Protocol Optimization

### 7.1 HTTP Pipelining
- [ ] Parse multiple requests from single read
- [ ] Queue responses in order
- [ ] Batch writes for pipelined responses

### 7.2 Keep-Alive Optimization
- [ ] Persistent connection reuse (already exists)
- [ ] Optimal timeout tuning
- [ ] Connection: keep-alive header handling

### 7.3 Response Optimization
- [ ] Pre-computed static responses (Date header, Server header)
- [ ] Vectored I/O (writev) for headers + body
- [ ] Avoid string formatting in hot path

---

## Phase 8: Advanced Features (Post-MVP)

### 8.1 HTTP/2
- [ ] HPACK header compression
- [ ] Stream multiplexing
- [ ] Server push

### 8.2 HTTP/3 (QUIC)
- [ ] UDP-based transport
- [ ] 0-RTT connection establishment
- [ ] Built-in encryption

### 8.3 TLS
- [ ] TLS 1.3 support
- [ ] io_uring + TLS integration
- [ ] Session resumption

### 8.4 WebSockets
- [ ] Upgrade handshake handling
- [ ] Frame parsing/serialization
- [ ] Ping/pong keepalive
- [ ] Per-message compression (permessage-deflate)

### 8.5 Static File Serving
- [ ] sendfile() / io_uring splice
- [ ] ETag / If-None-Match support
- [ ] Gzip/Brotli compression
- [ ] Range requests for partial content
- [ ] Directory listing (optional)

---

## Benchmark Targets

| Framework | Language | Target | Notes |
|-----------|----------|--------|-------|
| Axum | Rust | Beat by 10%+ | Tokio runtime, very optimized |
| GoFiber | Go | Beat by 20%+ | fasthttp underneath |
| Drogon | C++ | Match | One of the fastest |
| uWebSockets | C++ | Match | Claims fastest |
| may-minihttp | Rust | Match | Minimal, very fast |

Primary metric: Requests/second on plaintext benchmark at 256 connections.
Secondary: p99 latency under load.

---

## Implementation Order

1. **Phase 1** ✅ - Benchmarks done
2. **Phase 2** ✅ - Developer experience (hot reload implemented)
3. **Phase 3** ✅ - Multi-threading (thread-per-core with SO_REUSEPORT)
4. **Phase 4** ✅ - io_uring optimization (multishot, registered buffers/files, SQPOLL)
5. **Phase 5** - SIMD parsing (CPU-bound improvements)
6. **Phase 6** - Memory optimization (polish)
7. **Phase 7** - Protocol optimization (diminishing returns)
8. **Phase 8** - Future features

---

## Quick Wins (Do First)

These are low-effort, high-impact:

1. ~~**Hot reload**~~ ✅ - Dramatically improves development speed
2. ~~**SO_REUSEPORT multi-threading**~~ ✅ - 4-8x throughput on multi-core
3. ~~**Multishot accept**~~ ✅ - Reduces accept syscalls
4. **Pre-computed Date header** - Updated once per second, not per request
5. ~~**Batch io_uring submissions**~~ ✅ - Single syscall for multiple ops

---

## Changelog

### v0.4.0 (Current)
- io_uring optimizations (Linux):
  - Multishot accept (single SQE for multiple accepts)
  - Registered buffers and files support
  - SQPOLL mode for zero-syscall submissions
  - Submission batching APIs
- Configurable io_uring options: `io_uring_sqpoll`, `io_uring_multishot_accept`
- Fixed dangling pointer bug in WorkerPool initialization

### v0.3.0
- Multi-threading with thread-per-core model
- SO_REUSEPORT for kernel load-balancing across workers
- Auto-detect CPU count (configurable via `num_workers`)
- Worker and WorkerPool abstractions for advanced use

### v0.2.0
- Hot reload development mode (`zig build dev -- <target>`)
- File watching via kqueue (macOS/BSD) and inotify (Linux)
- Signal handling for graceful shutdown
- Automatic rebuild and server restart on file changes

### v0.1.0
- Initial release
- Express-style routing (GET, POST, PUT, DELETE, PATCH)
- JSON parsing/serialization with comptime reflection
- Middleware support (logger, CORS)
- Zero-copy HTTP parsing
- io_uring (Linux) / kqueue (macOS) async I/O
- Connection pooling
- Security hardening (request limits, DoS protection)
- Benchmark suite (plaintext, json, db, queries)
