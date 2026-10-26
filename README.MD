# Product Search Service: Load Testing and Scaling on ECS Fargate

This is a Go + Gin product service with a search endpoint that does a fixed amount of work per request. I deployed it to ECS Fargate with Terraform, load tested it with Locust, and watched it with both my Homework 5 Prometheus/Grafana dashboard and CloudWatch. Part II finds where a single task breaks. Part III puts it behind a load balancer with auto scaling.

| Method | Path | Notes |
|---|---|---|
| `GET` | `/products/search?q={query}` | New. Case-insensitive match on name or category, checks exactly 100 products, returns at most 20 |
| `GET` | `/products/{productId}` | From Homework 5 |
| `POST` | `/products/{productId}/details` | From Homework 5 |
| `GET` | `/health` | Health check for the load balancer (Part III) |
| `GET` | `/metrics` | Prometheus metrics |

**Contents:** [Part II: finding the breaking point](#part-ii-finding-the-breaking-point) · [Part III: horizontal scaling](#part-iii-horizontal-scaling-with-auto-scaling) · [Where everything is](#where-everything-is) · [Deploy](#deploy) · [Search requests](#search-requests) · [Run the load tests](#run-the-load-tests) · [Observability](#observability) · [Clean up](#clean-up) · [Troubleshooting](#troubleshooting)

---

## Part II: Finding the breaking point

### Setup

| | |
|---|---|
| Service | ECS Fargate, 256 CPU units (0.25 vCPU), 512 MB, 1 task, us-west-2 |
| Data | 100,000 products generated at startup, named `Product <Brand> <ID>`, with categories rotated by modulo through 10 names |
| Work per request | Each search checks exactly 100 products (a rotating window over the catalog), single-threaded, and returns at most 20 |
| Load | Locust `FastHttpUser` searching 12 common terms (`electronics`, `books`, `alpha`, `product`, …) with a 0–10 ms wait |
| Load generator | EC2 `t3.medium` in us-west-2, hitting the task's private IP. My first attempt was from my laptop (see [creative stress testing](#5-creative-stress-testing)) |
| Monitoring | HW5 Grafana dashboard (Prometheus scrapes `/metrics` every 5 s), CloudWatch `AWS/ECS` service metrics, and CloudWatch Logs |

Before load testing I checked single searches from the EC2 instance ([`verification_single_search.txt`](results/data/verification_single_search.txt)). Each took about 1.5 ms end to end and about 0.1 ms inside the handler, well under the 20 ms target. Four searches raised the `search_products_checked_total` counter by exactly 400, which confirmed 100 products per search. A single user was already enough to push the task to about 23% CPU.

### Results

| Test | Users | Duration | Requests | Failures | req/s | p50 | p95 | p99 | CloudWatch CPU (avg) | CloudWatch memory |
|---|---|---|---|---|---|---|---|---|---|---|
| 1: baseline | 5 | 2 min | 85,370 | 0 | 712 | 1 ms | 1 ms | 5 ms | ~77% | 10.6% (flat) |
| 2: breaking point | 20 | 3 min | 191,421 | 0 | 1,065 | 1 ms | 66 ms | 87 ms | ~97–99% | 10.8% (flat) |
| 3: step load | 1 → 40 | 3.5 min | 144,567 | 0 | 688 | 1 ms | 75 ms | 89 ms | 23% → 100% | flat |

![HW5 Grafana dashboard and CloudWatch side by side across Test 1 and Test 2](results/screenshots/both_tests_side_by_side.png)

### 1. What happened when load increased

With 5 users the task ran at about 77% CPU and served 712 req/s with a p99 of 5 ms. With 20 users, 4× the users only got 1.5× the throughput (1,065 req/s). CPU sat at 97–99% and p90/p95/p99 jumped to 62/66/87 ms. Nothing failed; requests just got slower.

The step test ([`test3_step_by_step.csv`](results/data/ec2/test3_step_by_step.csv)) shows where it breaks:

| Users | 1 | 2 | 3 | 5 | 10 | 20 | 40 |
|---|---|---|---|---|---|---|---|
| req/s | 145 | 296 | 423 | 721 | 892 | 1,069 | 1,151 |
| CPU | 23% | 38% | 53% | 77% | 95% | 99% | 100% |
| p95 | 1 ms | 1 ms | 1 ms | 1 ms | 2 ms | 30 ms | 70 ms |

Throughput grows linearly, about 145 req/s per user, up to 5–10 users. Then it flattens around 1,100–1,150 req/s, and extra users only add latency. Going from 20 to 40 users gave 8% more throughput and more than doubled p95.

The ~65 ms latency has a specific cause. A 0.25 vCPU task gets 25 ms of CPU in every 100 ms period, and once it uses that, Fargate pauses the whole process until the next period. I could see this in the request logs ([`request_logs.md`](results/data/request_logs.md)): even at ~1,000 req/s, consecutive log lines had ~65 ms gaps with nothing in between.

Memory stayed at 10.5–10.8% of 512 MB (about 68 MiB) the whole time, since all the products are generated at startup.

### 2. Optimization or scaling? The evidence

| Evidence | Source | What it means |
|---|---|---|
| Products checked per search was 100 in every test | Grafana panel from `search_products_checked_total` | The code wasn't doing more work under load |
| Time inside the handler barely changed from 5 to 20 users: p50 0.107 → 0.110 ms, p99 0.26 → 0.39 ms | CloudWatch Logs Insights over every request | The search itself didn't get slower |
| Client p95 went from 1 to 66 ms while the handler stayed under 0.4 ms | Locust vs. Prometheus and the logs | The extra time is spent waiting for CPU, not computing |
| CPU pinned at 99–100% while throughput leveled off at ~1,100 req/s | CloudWatch CPUUtilization and the step test | The task is out of CPU |
| Memory flat at ~10% | CloudWatch MemoryUtilization | Not a memory problem |
| CPU cost per request roughly constant (~0.09% CPU per req/s under load) | CPU ÷ req/s at each step | More CPU should mean proportionally more throughput |

I concluded this needs scaling, not optimization. The search does a fixed 100 checks by design (like running a model or processing a video frame), and the cost per request doesn't grow with load. I could shave some constant overhead, like JSON encoding or the `ToLower` allocations, but demand grows by about 145 req/s per user, so any fixed ceiling gets hit again. The real fix is more CPU, either more tasks (horizontal) or a bigger task (vertical).

### 3. Using CloudWatch metrics to make a scaling decision

From CloudWatch CPU against the throughput I measured, one task tops out around 1,100 req/s at 100% CPU, or about 770 req/s at a 70% target. Each user sends about 145 req/s when it isn't being throttled, so Test 2's 20 users want roughly 2,900 req/s. At a 70% target that's 2,900 ÷ 770 ≈ 4 tasks (3 tasks would run at about 88%).

To test this as a real trigger, I created a CloudWatch alarm, `CS6650-search-cpu-high`, that fires when average service `CPUUtilization` is over 70% for one minute. That's the same signal ECS Service Auto Scaling uses with target tracking. During the step test it went into ALARM on the 18:48 datapoint (96%, during the 10–20 user steps).

![CloudWatch CPU during the step test with the 70% alarm threshold](results/screenshots/test3_step_cloudwatch_alarm.png)

The alarm fired at 18:51:53, about 4 minutes after CPU crossed 70%, because ECS metrics are 1-minute averages that arrive late. For spiky traffic I'd use a lower threshold or keep spare capacity instead of relying on the alarm alone. Memory stayed around 10%, so it isn't a useful scaling signal for this service. One catch: each task had its own public IP at this point, so extra tasks wouldn't help until something spread traffic across them. That's what Part III adds.

### 4. HW5 dashboard vs. CloudWatch, side by side

Same Test 2 window (20 users), with Grafana on the left and CloudWatch on the right:

![Test 2: Grafana and CloudWatch side by side](results/screenshots/test2_20u_side_by_side.png)

| | HW5 Grafana dashboard (Prometheus) | CloudWatch |
|---|---|---|
| What it told me that the other didn't | Request rate, error rate, latency inside the handler, errors by status, and products checked per search. This is the app's view: the search stayed at ~0.1 ms and always checked 100 products. | CPU and memory as a percentage of what the task is allowed (0.25 vCPU, 512 MB), measured by the platform instead of my code. Grafana showed 68 MiB of memory but not that it's only 10% of the limit. Also alarms that can drive scaling, and Logs Insights over every request, without me running anything. |
| Resolution | 5 s, so each 30-second step of the step test shows up as its own level | 1 min, so the steps blur into one ramp, and the data shows up 2–4 min late |
| Blind spots | Knows nothing about the task's limits. If my laptop running Prometheus is off, nothing gets recorded. | No request rate or latency for this service yet (no load balancer), and no way to see why CPU is high |

Put together, CloudWatch said the task was out of CPU, and Grafana said the code wasn't any slower and requests were just waiting. That combination is what pointed me to scaling instead of optimization. The two also agreed where they overlapped: my Grafana CPU panel (from `process_cpu_seconds_total`) read 77% and 99% for Tests 1 and 2, and CloudWatch read 77.6% and 98.6%.

<details>
<summary>Test 1 and step test side by side, and the Locust reports</summary>

**Test 1 (5 users)**
![Test 1 side by side](results/screenshots/test1_5u_side_by_side.png)

**Test 3, step load (1 → 40 users)**
![Step test side by side](results/screenshots/test3_step_side_by_side.png)

**Locust reports**
![Test 1 Locust report](results/screenshots/test1_5u_locust_report.png)
![Test 2 Locust report](results/screenshots/test2_20u_locust_report.png)
![Step test Locust report](results/screenshots/test3_step_locust_report.png)

</details>

### 5. Creative stress testing

1. **The same test from two places.** My first run was from my laptop and only reached 43 and 162 req/s at 5 and 20 users, with CPU at 3–7% and 17%. That looked exactly like the handout's "CPU under 40% with 20 users means you're checking too few products." But the products-checked metric showed 100 per search, and latency was flat at ~110 ms (the round trip from my laptop to us-west-2) at both loads, so the load generator was the bottleneck, not the server. Moving Locust onto EC2 in the same region gave 17× the throughput at 5 users and exposed the real CPU limit.

   ![Laptop run: CloudWatch CPU stays under 20% at 20 users](results/screenshots/laptop_test2_20u_cloudwatch_cpu.png)

2. **A step-load test** (`locust/step_locustfile.py`): 1 → 2 → 3 → 5 → 10 → 20 → 40 users, 30 s each, to find the knee instead of guessing from two data points.
3. **A correctness check built into the service.** I added the `search_products_checked_total` counter and graphed products checked per search, so I could rule out "checking too many or too few products" while a test was running.
4. **Digging through the logs.** I used Logs Insights for per-test handler percentiles and found the ~65 ms CPU-throttling gaps in the raw log timeline.
5. **Testing the scaling trigger for real.** I ran load against the CloudWatch alarm instead of just setting it up.

### Data

Everything behind these numbers is in [`results/data/`](results/data):

| File | Contents |
|---|---|
| `ec2/test*_stats.csv`, `ec2/test*_stats_history.csv`, `ec2/test*_locust_report.html`, `ec2/test*_summary.txt` | Locust output for Tests 1–3, with start/end times (UTC) |
| `ec2/test3_step_by_step.csv` | Per-step req/s, latency, CPU, handler p99 |
| `prometheus_timeseries.csv` | 5 s series for all three tests: CPU, memory, req/s, handler p50/p99, products checked per search |
| `cloudwatch_datapoints.csv` | CloudWatch 1-minute CPU and memory (average, maximum) |
| `request_logs.md` | Logs Insights results, the CPU-throttling gaps, slow-request lines |
| `verification_single_search.txt` | Single-search checks before load testing |
| `laptop/` | The first runs, from my laptop |

---

## Part III: Horizontal scaling with auto scaling

### Setup

The service and search logic are unchanged (100,000 products, 100 checked per search). The only code change is a `GET /health` endpoint for the load balancer.

| | |
|---|---|
| Load balancer | ALB on port 80 → target group with target type IP, HTTP on 8080, health check on `/health` every 30 s, healthy after 2 passes, 30 s deregistration delay |
| Auto scaling | Target tracking on average service CPU at 70%, min 2 and max 4 tasks, 300 s scale-out and scale-in cooldowns |
| Tasks | Same size as Part II: 0.25 vCPU, 512 MB |
| Load | The Part II breaking-point test (20 users, `search_locustfile.py`) from EC2 in us-west-2 against the ALB's DNS name, held for 20 minutes so there's time for scaling to happen |
| Monitoring | A CloudWatch dashboard, `CS6650-search-scaling` (per-task CPU, desired/running tasks, healthy targets, ALB requests, latency and errors), next to the HW5 Grafana dashboard scraping every task |

### Core test: the load that broke Part II

The test ran for 20 minutes and served 2,116,975 requests with 0 failures, even though I stopped three tasks in the middle of it.

![CloudWatch dashboard during the core test, with scaling and failure events marked](results/part3/screenshots/core_cloudwatch.png)

![HW5 Grafana dashboard during the same test: per-task requests and CPU](results/part3/screenshots/core_grafana.png)

| | Part II (1 task) | Part III, 2 tasks (first 6 min) | 3 tasks | 4 tasks |
|---|---|---|---|---|
| Throughput | 1,065 req/s | ~1,330 req/s | ~1,820 req/s | ~2,300 req/s |
| p50 | 1 ms | 1–2 ms | 1–2 ms | 1–2 ms |
| p95 | 66 ms | 50–54 ms | 24–28 ms | 1–2 ms |
| p99 | 87 ms | ~82 ms | 68–76 ms | 51–59 ms |
| Service CPU (avg) | ~99% | ~91% | ~83% | 70–77% |
| Failures | 0 | 0 | 0 | 0 |

The Part III latencies are the ALB's per-minute `TargetResponseTime`, and Part II's are from Locust. The first 3 minutes of this run are exactly the Part II test, just on 2 tasks.

Timeline (UTC), from [`timeline.csv`](results/part3/data/timeline.csv) and [`events.txt`](results/part3/data/events.txt):

| Time | What happened |
|---|---|
| 14:37:32 | 20 users start. 2 tasks at ~91% CPU, p95 ~52 ms |
| 14:43:36 | The scale-out alarm (3 minutes above 70%) fires and desired count goes 2 → 3, about 6 min after load started |
| 14:44:36 | The new task passes 2 health checks, so 3 healthy targets (~60 s after the decision) |
| 14:49:32 | Resilience test: I stopped 1 of the 3 tasks. The target group shows it as `draining` and ECS starts a replacement |
| 14:50:32 | Replacement healthy, back to 3 |
| 14:50:36 | Cooldown is over and CPU is still above 70%, so desired goes 3 → 4 |
| 14:51:21 | 4 healthy targets, and p95 drops to 1–2 ms |
| 14:53:34 | I stopped 2 of the 4 tasks at once. The other 2 carry ~1,300 req/s while ECS replaces them |
| 14:54:43 | 4 healthy again (~70 s). The only visible effect was one minute of p95 at 12 ms |
| 14:57:35 | Test ends with 0 failures |

### 1. How horizontal scaling solved the Part II bottleneck

The Part II bottleneck was CPU. One 0.25 vCPU task maxes out around 1,100 req/s, and past that, requests queue up behind Fargate's CPU throttling (the ~65 ms pauses). Horizontal scaling adds CPU by adding tasks, and the ALB splits the requests between them.

The Grafana "Search requests per task" panel shows the ALB giving each task the same share: about 650 req/s each with 2 tasks and about 600 with 3 or 4. Total throughput went from 1,330 to 1,820 to 2,300 req/s as the service went from 2 to 3 to 4 tasks, about +500 req/s per task, until it covered what the 20 users were asking for. Once there was spare CPU, p95 fell from 66 ms in Part II to 1–2 ms. Time inside the handler stayed under ~1.5 ms and products checked stayed at 100 per search the whole time, so the service didn't get faster code, it got more CPU.

One thing I didn't expect: CPU wasn't equal across tasks even though requests were. With 3 tasks each serving ~600 req/s, CPU read about 97%, 85% and 70% (both CloudWatch per-task CPU and Grafana show this). My guess is the tasks landed on different underlying hosts, so the same number of requests costs a different amount of CPU on each. Target tracking only looks at the average, so the hottest task can still be throttled while the service looks like it's at target.

### 2. Role of each component

| Component | What it does here |
|---|---|
| Application Load Balancer | Gives clients one stable address (`CS6650-search-alb-….elb.amazonaws.com`, port 80) in front of a changing set of tasks. It spreads requests across healthy targets, stops sending to a target that fails health checks, and reports request count, target response time and 5XX errors to CloudWatch. In Part II the task's IP changed every time it restarted. |
| Target group | The set of tasks the ALB can send traffic to, registered by IP since Fargate tasks don't have instance IDs, on HTTP port 8080. It checks each target with `GET /health` every 30 s, and a target needs 2 passes in a row to be healthy. ECS registers new tasks and deregisters stopped ones automatically, and deregistration gives in-flight requests 30 s to finish. |
| Auto scaling (target tracking) | Watches the service's average `CPUUtilization` and changes the ECS service's desired count (between 2 and 4) to keep it near 70%. It sets up two CloudWatch alarms: one scales out after 3 one-minute datapoints above 70%, and the other scales in after 15 below ~63%. The 300 s cooldowns stop it from reacting to its own last change. |
| ECS service | Turns the desired count into running Fargate tasks, replaces tasks that stop or fail ALB health checks, and registers each one with the target group. |

### 3. Horizontal vs. vertical scaling

| | Horizontal (this setup: more 0.25 vCPU tasks) | Vertical (one bigger task, e.g. 1 vCPU) |
|---|---|---|
| Ceiling | Max tasks × ~1,100 req/s, raised by changing one number | The largest Fargate size (16 vCPU), and one process has to be able to use all of it |
| Failure | Losing a task removes 1/N of capacity and the ALB routes around it | Losing the task is a full outage until a new one starts |
| Changing capacity | Tasks are added and removed under load with no downtime | A new task size means replacing the task |
| How fast it reacts | Minutes (alarm, task start, 2 health checks) | Minutes, plus a restart |
| Extra parts and cost | An ALB (~$0.02/h plus usage), health checks, and no state stored in a single task | Nothing extra; simpler to run and reason about |
| Fit for this service | Very good: every task generates the same 100,000 products, so any task can answer any search | Fine until one machine isn't enough or a single failure isn't acceptable |

This service also shows the main catch with horizontal scaling. Products created with `POST /products/{id}/details` only exist in the memory of the task that handled the request, so a later `GET` can land on a different task and return 404. The search path is already stateless, but the write path would need a shared store like DynamoDB or Redis before it could scale this way.

### 4. Predicted scaling behavior for different load patterns

These predictions come from the numbers measured in the Part II step test and this core test: a task handles ~1,100 req/s at 100% CPU (~770 at 70%), each user sends ~100–150 req/s, scale-out needs 3 one-minute datapoints above target, and a new task takes ~50–60 s to start and pass 2 health checks.

| Load pattern | Predicted behavior |
|---|---|
| Sudden heavy load (the core test: 20 users at once) | Measured: about 6 minutes of degraded p95/p99 before the first new task, then one more task per 300 s cooldown, so about 13 minutes to reach 4 tasks. The cooldown sets the pace more than detection does. |
| Gradual ramp | Scaling should keep up, because CPU crosses 70% while there's still headroom before 100%, so new tasks arrive before latency gets much worse. A new task would get added roughly every time load grows by ~770 req/s. |
| Spike from quiet (2 → 40 users) | The worst case. The 2 minimum tasks saturate right away, the first new task takes 5–6 minutes, and reaching 4 takes about 11. Even 4 tasks aren't enough for 40 users (40 × ~130 ≈ 5,200 req/s vs. ~4,400 capacity), so CPU stays pinned and latency stays high at max capacity. A higher minimum, step scaling for big jumps, or a higher max would help. |
| Short bursts (under 3 min) | No scaling at all, since the alarm needs 3 straight minutes above target. Only the minimum task count matters. |
| Load drops | Scale-in is slow on purpose: 15 minutes below ~63% CPU, then one task per 300 s cooldown, and never below 2. |
| Policy changes | A 50% target would scale out sooner and run more tasks (lower latency, higher cost). A 90% target waits until tasks are almost saturated, and on 0.25 vCPU that means the ~65 ms throttling latency is already showing. Shorter cooldowns would reach max capacity faster but could overshoot, and a minimum of 3–4 tasks would absorb spikes without waiting. |

### 5. CPU vs. a request metric as the scaling trigger

Here's what each signal showed during the scale-out:

- CloudWatch CPU was above 70% from the first full minute (14:38, 92%). The scale-out happened at 14:43:36, after 3 one-minute datapoints plus 2–3 minutes of CloudWatch delay.
- User-facing latency (the ALB's `TargetResponseTime` and Locust) was also bad in the first minute, with p95 around 52 ms. Latency stays flat until a task saturates and then jumps (in the Part II step test it was 1 ms up to 5 users, then 30–70 ms), so it tells you a task is already saturated, not that it's getting close.
- In-handler duration on the HW5 Grafana dashboard only went from ~0.4 ms to ~1.5 ms p99. The time was being spent waiting for CPU outside the handler, so a trigger on app-level request duration would never have fired.
- Requests per target (the Grafana per-task panel and the ALB's `RequestCountPerTarget`) was ~650 req/s per task from the first minute, steady and proportional to CPU, because every search costs the same.

So a latency or request-count trigger wouldn't have scaled much sooner. All three CloudWatch signals crossed their thresholds in the same first minute, and most of the delay came from how the alarm works (3 datapoints, publishing lag, cooldown), not from which metric it watched. A trigger on in-handler duration would have been later; it would never have fired.

For this workload I'd stick with CPU, or switch to `ALBRequestCountPerTarget`, which is basically the same signal here. The work is fixed-cost and CPU-bound, so CPU measures the actual bottleneck, and request count per target tracks it in a straight line (~770 req/s per task ≈ 70% CPU). Request count has two advantages: it doesn't depend on which host a task lands on (CPU ranged from 70% to 97% for the same request rate), and it shows saturation coming before latency moves. I'd keep latency as an alert on user experience rather than the scaling trigger, since it only reacts after users are already affected and it can rise for reasons more tasks won't fix, like the network or a slow dependency.

### 6. Resilience and creative stress testing (exploration)

| Experiment | What I did | What happened |
|---|---|---|
| Stop one task under load (the resilience test) | At 14:49:32, stopped 1 of 3 tasks with `aws ecs stop-task` (same as Stop in the console) | Within ~15 s the target group marked it `draining` and the ALB stopped routing to it. ECS started a replacement right away, and it was healthy ~60 s later. 0 failed requests, and p95/p99 barely moved. |
| Stop several tasks at once | At 14:53:34, stopped 2 of 4 tasks together | Throughput dropped to what 2 tasks can serve (~1,300 req/s) for about a minute while ECS replaced both, and all 4 were healthy again after ~70 s. 0 failed requests, and one minute of p95 at 12 ms. |
| Make every task fail its health check | At 14:59:23, pointed the health check at `/does-not-exist` under the same 20-user load, then restored `/health` at 15:03:23 | About 90 s later all 4 targets were unhealthy, but the ALB kept returning 200s. When no targets are healthy, an ALB "fails open" and routes to all of them anyway. Meanwhile ECS treated the unhealthy tasks as failed and kept replacing them: it started new tasks first (up to 8 running), then stopped the old ones, and the new ones failed the same broken check. After I fixed the path, targets were healthy within ~40 s and the extra tasks drained. 866,930 requests, 0 failures, no ALB 5XX errors. So a bad health check didn't cause an outage here, but it caused constant task churn, and if the app were actually broken, failing open would send users to broken tasks. |
| Longer test | Held the Part II load for 20 minutes instead of 3 | This was necessary to see scaling at all. The first scale-out came at minute 6 and max capacity at minute 14, so a 3-minute test ends before anything scales. |
| Load generator inside AWS (carried over from Part II) | Locust on EC2 in the same region, with 2 processes | Kept the load generator from being the bottleneck. It sustained ~2,300 req/s through the ALB with 2 ms medians. |

![CloudWatch while every health check failed: unhealthy targets and task churn, but no errors](results/part3/screenshots/healthfail_cloudwatch.png)

<details>
<summary>Locust report for the core test</summary>

![Core test Locust report](results/part3/screenshots/core_locust_report.png)

</details>

The gradual-ramp and spike load shapes are in `locust/ramp_locustfile.py` and `locust/spike_locustfile.py`, and the CPU target, min/max and cooldowns are Terraform variables (`terraform apply -var cpu_target=50 -var scale_out_cooldown=60`). Section 4 covers how I expect each of those to behave based on the measured capacity and scaling timings.

### Summary

The service now handles the load that broke it in Part II, with 0 errors and p95 back down to 1–2 ms at 4 tasks, and it kept serving requests while I stopped half its tasks. The single-task bottleneck from Part II became a capacity setting: the ALB spreads requests across identical tasks, health checks route around failures, and auto scaling decides how many tasks to run based on CPU.


---

## Where everything is

```
.
├── src/product-service.go      # handlers (incl. /products/search), product generation, metrics, JSON logs
├── terraform/                  # ECR, ECS (0.25 vCPU / 512 MB), ALB + target group, auto scaling, CloudWatch dashboard
├── loadgen/                    # launch.sh / run.sh / teardown.sh: Locust on EC2 in us-west-2 via Systems Manager
├── locust/
│   ├── search_locustfile.py    # Tests 1 and 2: FastHttpUser searching common terms
│   ├── step_locustfile.py      # Test 3: step load 1 → 40 users
│   ├── ramp_locustfile.py      # Part III exploration: 1 → 30 users over 15 min
│   ├── spike_locustfile.py     # Part III exploration: 2 → 40 users at once
│   └── locustfile.py           # HW5 GET/POST mix for the other two endpoints
├── observability/              # Prometheus + Grafana (+ image renderer), HW5 dashboard with CPU/memory/products-checked panels
├── postman/                    # HW5 collection for the other two endpoints
└── results/                    # Part II screenshots and data; results/part3/ for Part III
```

## Deploy

You need Terraform, the AWS CLI, Docker Desktop and an AWS Academy Learner Lab session (the Terraform reuses the lab's `LabRole`).

1. **Credentials:** in Learner Lab, open **AWS Details → AWS CLI: Show** and paste the block into `~/.aws/credentials`. Then run `aws configure set region us-west-2` and check with `aws sts get-caller-identity`. Credentials expire with the lab session (~4 h). Never commit them.
2. **Docker:** start Docker Desktop. On macOS, in the terminal you'll run Terraform from:
   ```bash
   export DOCKER_HOST=unix://$HOME/.docker/run/docker.sock
   ```
3. **Deploy:**
   ```bash
   cd terraform
   terraform init
   terraform apply        # Plan: 16 to add. Type yes
   ```
   This creates the ECR repo `ecr_search_service`, the cluster `CS6650-search-cluster` (Container Insights on), the service `CS6650-search` with 2 tasks, the ALB `CS6650-search-alb` and target group, the CPU target-tracking policy, the CloudWatch dashboard `CS6650-search-scaling` and the log group `/ecs/CS6650-search`. Scaling settings are variables: `terraform apply -var cpu_target=50 -var min_tasks=2 -var max_tasks=4 -var scale_out_cooldown=300 -var scale_in_cooldown=300`.
   ```bash
   terraform output alb_dns_name     # send traffic to http://<this>/products/search?q=...
   terraform output dashboard_url    # CloudWatch dashboard
   ```
4. **Get the task's IPs** (wait about a minute after the apply):
   ```bash
   TASK=$(aws ecs list-tasks --cluster CS6650-search-cluster --service-name CS6650-search --query 'taskArns[0]' --output text)
   ENI=$(aws ecs describe-tasks --cluster CS6650-search-cluster --tasks $TASK --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text)
   IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
   PRIVATE_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI --query 'NetworkInterfaces[0].PrivateIpAddress' --output text)
   echo "public: http://$IP:8080   private (from inside the VPC): http://$PRIVATE_IP:8080"
   ```

**Deploying code changes:** `terraform apply -replace=docker_image.app -replace=docker_registry_image.app`, then `aws ecs update-service --cluster CS6650-search-cluster --service CS6650-search --force-new-deployment`. The new task gets a new IP.

## Search requests

```bash
curl -s "http://$IP:8080/products/search?q=electro"
```
```json
{"products":[{"product_id":110,"name":"Product Beta 110","sku":"SKU-000110","manufacturer":"Beta Corporation","category_id":1,"weight":110,"some_other_id":111}, ...],"total_found":10,"search_time":"96.196µs"}
```

| Request | Response |
|---|---|
| `?q=electro`, `?q=BOOKS`, `?q=alpha` | `200`. Matches in name or category, case-insensitive, at most 20 |
| `?q=zzz` | `200` with `"products":[]`, `"total_found":0` |
| no `q`, or `?q=` | `400` `INVALID_INPUT` (`query parameter q is required`) |
| `q` longer than 100 characters | `400` `INVALID_INPUT` |

Each search checks the next 100 products of the catalog (the starting point rotates), so repeating a query returns different products. `search_time` is time spent in the handler. `total_found` is the number of products returned, capped at 20 per the spec.

## Run the load tests

**Part III (through the ALB, from EC2):**

```bash
loadgen/launch.sh        # t3.medium with Locust, driven by Systems Manager (no SSH)
loadgen/run.sh core locust/search_locustfile.py -u 20 -r 20 -t 20m --processes 2 --host http://$(terraform -chdir=terraform output -raw alb_dns_name)
loadgen/teardown.sh
```

Results land in `results/part3/data/<name>/`.

**Part II (single task):**

From the repo, against the public IP (`pip install locust`):

```bash
cd locust
locust -f search_locustfile.py --headless -u 5  -r 5  -t 2m --host http://$IP:8080 --csv test1_5u  --html test1_5u.html
locust -f search_locustfile.py --headless -u 20 -r 20 -t 3m --host http://$IP:8080 --csv test2_20u --html test2_20u.html
locust -f step_locustfile.py   --headless --host http://$IP:8080 --csv test3_step --html test3_step.html
```

**Run Locust inside AWS to load the server rather than your network.** From a laptop, each request pays the ~90 ms round trip, so 20 users can't push the task past ~20% CPU. For the results above, Locust ran on an EC2 `t3.medium` in us-west-2 (Amazon Linux 2023 with Python 3.11: `python3.11 -m venv venv && venv/bin/pip install locust`) against `http://$PRIVATE_IP:8080`. If your network blocks SSH, attach the `LabInstanceProfile` instance role and run commands through **Systems Manager → Run Command** or Session Manager.

## Observability

**Grafana + Prometheus against the ECS task.** Prometheus runs on your machine and scrapes the task's public IP:

```bash
cd observability
mkdir -p targets && echo "[{\"targets\": [\"$IP:8080\"]}]" > targets/ecs.json
docker compose up -d --no-deps prometheus grafana renderer
```

To follow every task while the service scales, run `./ecs-targets.sh` in another terminal. It rewrites `targets/ecs.json` with all running tasks' IPs every 15 s.

Open http://localhost:3000. The **Product API: RED signals** dashboard has rate, errors, latency, plus CPU (% of 0.25 vCPU), memory, and products checked per search. Export a PNG of any time range with:

```bash
curl -o dashboard.png "http://localhost:3000/render/d/product-api-red/?orgId=1&from=now-15m&to=now&width=1800&height=1150&kiosk"
```

`docker compose up --build -d` (without `--no-deps`) still runs the whole stack against a local copy of the API, as in HW5.

**CloudWatch:** ECS console → `CS6650-search-cluster` → `CS6650-search` → **Metrics** for CPU and memory, and `/ecs/CS6650-search` in CloudWatch Logs for request logs. To render the console's CPU graph to a PNG from the CLI:

```bash
aws cloudwatch get-metric-widget-image --output text --query MetricWidgetImage --metric-widget '{
  "metrics":[["AWS/ECS","CPUUtilization","ClusterName","CS6650-search-cluster","ServiceName","CS6650-search"]],
  "start":"-PT15M","period":60,"yAxis":{"left":{"min":0,"max":100}}}' | base64 -d > cpu.png
```

**Scaling alarm** (as used in the report):

```bash
aws cloudwatch put-metric-alarm --alarm-name CS6650-search-cpu-high \
  --namespace AWS/ECS --metric-name CPUUtilization \
  --dimensions Name=ClusterName,Value=CS6650-search-cluster Name=ServiceName,Value=CS6650-search \
  --statistic Average --period 60 --evaluation-periods 1 --threshold 70 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching
```

## Clean up

```bash
cd terraform && terraform destroy
loadgen/teardown.sh    # if you launched the load generator
cd ../observability && docker compose down
```

If you launched an EC2 load generator, terminate it too.

## Troubleshooting

| Problem | Fix |
|---|---|
| `ExpiredToken` | The lab session ended. Paste the new credentials into `~/.aws/credentials`. |
| `Cannot connect to the Docker daemon at unix:///var/run/docker.sock` | Start Docker Desktop and `export DOCKER_HOST=unix://$HOME/.docker/run/docker.sock`. |
| `curl` times out | The task restarted with a new IP. Redo step 4 of [Deploy](#deploy). |
| CPU stays low under load | Check Grafana's *Products checked per search* (should be 100). If it is, the load generator is the limit: run Locust from EC2 in the same region. |
| `pip install locust` fails building `gevent` on Amazon Linux | Its default Python 3.9 `pip` is too old. Use `python3.11` in a venv. |
| Prometheus target `product-api` is down | Expected when only scraping ECS. That job is the local copy of the API. |
