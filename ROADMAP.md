# Spark Performance Roadmap

Goal: Fastest web framework benchmarked against Tokio/Axum (Rust), GoFiber (Go), Drogon (C++), uWebSockets (C++).

## Current State

What's already optimized:
- io_uring (Linux) / kqueue (macOS) for async I/O
- Zero-copy HTTP parsing (slices into buffer)
- Connection and buffer pooling
- Arena allocation with O(1) reset

What's missing for top-tier performance:
- Single-threaded only
- No SIMD parsing
- Basic io_uring usage (no advanced features)
- No HTTP pipelining
- No benchmarking infrastructure

---

## Phase 1: Measurement Infrastructure

Can't optimize what you can't measure.

### 1.1 Benchmark Suite
- [ ] Add `benchmarks/` directory with standardized tests
- [ ] Plaintext response (`/plaintext` - "Hello, World!")
- [ ] JSON serialization (`/json` - `{"message":"Hello, World!"}`)
- [ ] Single query (`/db` - fetch one row)
- [ ] Multiple queries (`/queries?n=20`)
- [ ] Match TechEmpower benchmark formats

### 1.2 Benchmark Tooling
- [ ] Scripts to run wrk/wrk2/bombardier against Spark
- [ ] Comparison scripts against competitors (Axum, GoFiber, Drogon)
- [ ] Latency distribution tracking (p50, p99, p99.9)
- [ ] Throughput (req/sec) at various concurrency levels

### 1.3 Profiling Integration
- [ ] perf integration for Linux
- [ ] Instruments integration for macOS
- [ ] Flamegraph generation scripts

---

## Phase 2: Multi-threading

Single-threaded is the biggest current bottleneck.

### 2.1 Thread-per-core Model
- [ ] SO_REUSEPORT for multiple listeners
- [ ] One event loop per core (no cross-thread communication)
- [ ] Thread-local connection pools
- [ ] Thread-local arena allocators

### 2.2 Work Stealing (Optional)
- [ ] Lock-free work queue for load balancing
- [ ] Only if thread-per-core shows imbalance

---

## Phase 3: io_uring Optimization (Linux)

io_uring has features we're not using.

### 3.1 Multishot Accept
- [ ] IORING_ACCEPT_MULTISHOT - single SQE for multiple accepts
- [ ] Reduces submission overhead for accept-heavy workloads

### 3.2 Provided Buffers (Buffer Rings)
- [ ] IORING_OP_PROVIDE_BUFFERS - kernel-managed buffer pool
- [ ] Eliminates user-space buffer management overhead
- [ ] Automatic buffer selection by kernel

### 3.3 Registered Buffers & Files
- [ ] IORING_REGISTER_BUFFERS - pin buffers in kernel
- [ ] IORING_REGISTER_FILES - avoid fd lookup per operation
- [ ] Reduces per-operation overhead

### 3.4 Submission Batching
- [ ] Batch multiple SQEs before submit
- [ ] Single syscall for multiple operations

### 3.5 SQPOLL Mode
- [ ] IORING_SETUP_SQPOLL - kernel polling thread
- [ ] Zero syscalls for submissions
- [ ] Trade CPU for latency

---

## Phase 4: Parser Optimization

HTTP parsing is CPU-bound. SIMD helps.

### 4.1 SIMD HTTP Parsing
- [ ] Use `@Vector` for parallel byte scanning
- [ ] Find delimiters (space, CRLF, colon) in 16/32 bytes at once
- [ ] Reference: picohttpparser, llhttp

### 4.2 Method Parsing Optimization
- [ ] Compare first 4/8 bytes as integer (already partially done)
- [ ] Jump table for method dispatch

### 4.3 Header Parsing
- [ ] SIMD search for `\r\n`
- [ ] Fast case-insensitive comparison for common headers
- [ ] Pre-hash common header names

### 4.4 URL Parsing
- [ ] SIMD search for `?`, `#`, space
- [ ] Avoid per-character branching

---

## Phase 5: Memory Optimization

Cache misses are expensive.

### 5.1 Hot/Cold Data Separation
- [ ] Frequently accessed fields in first cache line (64 bytes)
- [ ] Connection struct layout optimization
- [ ] Benchmark with `perf stat` cache metrics

### 5.2 Arena Improvements
- [ ] Bump allocator (simpler than current arena)
- [ ] Pre-warm arenas to avoid page faults
- [ ] Huge pages for buffer pools (2MB pages)

### 5.3 Object Pooling
- [ ] Pool parsed request objects
- [ ] Pool response builders
- [ ] Avoid allocation in hot path entirely

---

## Phase 6: Protocol Optimization

### 6.1 HTTP Pipelining
- [ ] Parse multiple requests from single read
- [ ] Queue responses in order
- [ ] Batch writes for pipelined responses

### 6.2 Keep-Alive Optimization
- [ ] Persistent connection reuse (already exists)
- [ ] Optimal timeout tuning
- [ ] Connection: keep-alive header handling

### 6.3 Response Optimization
- [ ] Pre-computed static responses (Date header, Server header)
- [ ] Vectored I/O (writev) for headers + body
- [ ] Avoid string formatting in hot path

---

## Phase 7: Advanced Features (Post-MVP)

### 7.1 HTTP/2
- [ ] HPACK header compression
- [ ] Stream multiplexing
- [ ] Server push

### 7.2 HTTP/3 (QUIC)
- [ ] UDP-based transport
- [ ] 0-RTT connection establishment
- [ ] Built-in encryption

### 7.3 TLS
- [ ] TLS 1.3 support
- [ ] io_uring + TLS integration
- [ ] Session resumption

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

1. **Phase 1** - Must have benchmarks before optimizing
2. **Phase 2** - Multi-threading is highest impact
3. **Phase 3** - io_uring optimization (Linux-specific wins)
4. **Phase 4** - SIMD parsing (CPU-bound improvements)
5. **Phase 5** - Memory optimization (polish)
6. **Phase 6** - Protocol optimization (diminishing returns)
7. **Phase 7** - Future features

---

## Quick Wins (Do First)

These are low-effort, high-impact:

1. **SO_REUSEPORT multi-threading** - 4-8x throughput on multi-core
2. **Multishot accept** - Reduces accept syscalls
3. **Pre-computed Date header** - Updated once per second, not per request
4. **Batch io_uring submissions** - Single syscall for multiple ops
