# Spark Benchmarks

This directory contains a suite of standardized benchmarks for measuring Spark's performance. The benchmarks are designed to match the [TechEmpower benchmark format](https://www.techempower.com/benchmarks/) for fair comparison against other frameworks.

## Benchmark Applications

### 1. Plaintext (`plaintext.zig`)

**Endpoint:** `GET /plaintext`

**Response:** `Hello, World!` (text/plain)

**Purpose:** Measures the absolute minimum HTTP overhead - the core request/response path without JSON serialization.

**Port:** 9000

### 2. JSON (`json.zig`)

**Endpoint:** `GET /json`

**Response:** `{"message": "Hello, World!"}` (application/json)

**Purpose:** Measures JSON serialization overhead on a simple response.

**Port:** 9001

### 3. Single Query (`db.zig`)

**Endpoint:** `GET /db`

**Response:** `{"id": 1, "randomNumber": 42}` (application/json)

**Purpose:** Simulates a single database query benchmark. Currently returns mock data.

**Port:** 9002

### 4. Multiple Queries (`queries.zig`)

**Endpoint:** `GET /queries?n=<count>`

**Response:** Array of `{"id": <id>, "randomNumber": <number>}` objects

**Purpose:** Simulates multiple database queries. The `n` parameter controls how many rows are returned (default: 1, max: 20).

**Port:** 9003

## Building Benchmarks

Build all benchmarks:
```bash
zig build bench
```

Build individual benchmarks:
```bash
zig build run-bench-plaintext
zig build run-bench-json
zig build run-bench-db
zig build run-bench-queries
```

## Running Benchmarks

With the benchmark tooling scripts (see `scripts/`):

```bash
# Run plaintext benchmark with wrk (256 connections, 30s)
./scripts/bench.sh plaintext

# Run with custom parameters
./scripts/bench.sh plaintext -c 512 -d 60

# Run all benchmarks
./scripts/bench.sh all

# Compare against other frameworks
./scripts/compare.sh

# Profile with perf (Linux)
./scripts/profile-linux.sh plaintext

# Profile with Instruments (macOS)
./scripts/profile-macos.sh plaintext
```

## Expected Performance

Baseline numbers (TBD - populate after first runs):

| Benchmark | Req/sec | p50 Latency | p99 Latency |
|-----------|---------|------------|------------|
| plaintext | TBD     | TBD        | TBD        |
| json      | TBD     | TBD        | TBD        |
| db        | TBD     | TBD        | TBD        |
| queries   | TBD     | TBD        | TBD        |

## Configuration

All benchmark applications are configured with:
- **Max connections:** 10,000
- **Buffer size:** 16 KB (default)
- **Read timeout:** 30s (default)
- **Write timeout:** 30s (default)

## Notes

- Benchmarks use `ReleaseFast` optimization by default
- No global middleware is registered (minimal overhead)
- Benchmarks are designed to run on localhost
- For best results, close other applications and ensure stable system load

## Future Work

- Integrate real database for `db.zig` and `queries.zig`
- Add HTTP/2 and TLS benchmarks
- Automated regression testing in CI/CD
- More detailed latency analysis (p75, p90, etc.)
