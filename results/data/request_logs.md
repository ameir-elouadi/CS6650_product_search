# Request logs (CloudWatch Logs, `/ecs/CS6650-search`)

One JSON line per request, written by the `observe` middleware. `duration_ms` is time inside the handler.

## Logs Insights: handler duration per test

```
filter endpoint="/products/search"
| stats count(*) as requests, avg(duration_ms) as avg_ms, pct(duration_ms,50) as p50_ms,
        pct(duration_ms,99) as p99_ms, max(duration_ms) as max_ms,
        sum(duration_ms>20)*100/count(*) as pct_over_20ms
```

| Test | Requests | Avg ms | p50 ms | p99 ms | Max ms | % over 20 ms |
|---|---|---|---|---|---|---|
| Test 1 (5 users), 18:37:45–18:39:46 UTC | 85,370 | 0.127 | 0.107 | 0.258 | 84.9 | 0.007% |
| Test 2 (20 users), 18:40:02–18:43:02 UTC | 191,441 | 0.333 | 0.110 | 0.389 | 174.3 | 0.305% |

The handler's median and p99 barely move between 5 and 20 users. Client-side p95 went from 1 ms to 66 ms, so that time was spent outside the handler, waiting for CPU.

## Consecutive lines during Test 2: a ~65 ms freeze

```json
{"time":"2026-10-25T18:41:59.989862789Z","level":"INFO","msg":"request","method":"GET","endpoint":"/products/search","path":"/products/search","status":200,"duration_ms":0.101}
{"time":"2026-10-25T18:41:59.990491888Z","level":"INFO","msg":"request","method":"GET","endpoint":"/products/search","path":"/products/search","status":200,"duration_ms":0.077}
{"time":"2026-10-25T18:42:00.055153292Z","level":"INFO","msg":"request","method":"GET","endpoint":"/products/search","path":"/products/search","status":200,"duration_ms":0.136}
```

Nothing is logged between 18:41:59.990 and 18:42:00.055, even at ~1,000 req/s. A 0.25 vCPU Fargate task gets 25 ms of CPU per 100 ms period; once it's used, the whole process is paused for the rest of the period (~65–75 ms). That pause is the 62–66 ms p90/p95 Locust measured.

## Requests caught mid-pause (filter `{ $.duration_ms > 5 }`, Test 2)

```json
{"time":"2026-10-25T18:40:02.849840428Z","level":"INFO","msg":"request","method":"GET","endpoint":"/products/search","path":"/products/search","status":200,"duration_ms":63.905}
{"time":"2026-10-25T18:40:03.249825657Z","level":"INFO","msg":"request","method":"GET","endpoint":"/products/search","path":"/products/search","status":200,"duration_ms":64.054}
{"time":"2026-10-25T18:40:03.654055022Z","level":"INFO","msg":"request","method":"GET","endpoint":"/products/search","path":"/products/search","status":200,"duration_ms":66.547}
```
