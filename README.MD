# Product Search Service: load testing and scaling on ECS Fargate

A Go + Gin product service with a fixed-cost search endpoint, deployed to one small ECS Fargate task with Terraform. It's load tested with Locust and observed two ways at once: the Homework 5 Prometheus/Grafana dashboard and CloudWatch.

| Method | Path | Notes |
|---|---|---|
| `GET` | `/products/search?q={query}` | **New.** Case-insensitive match on name or category, checks exactly 100 products, returns ≤ 20 |
| `GET` | `/products/{productId}` | From Homework 5 |
| `POST` | `/products/{productId}/details` | From Homework 5 |
| `GET` | `/metrics` | Prometheus metrics |

**Contents:** [Report](#report) · [Where everything is](#where-everything-is) · [Deploy](#deploy) · [Search requests](#search-requests) · [Run the load tests](#run-the-load-tests) · [Observability](#observability) · [Clean up](#clean-up) · [Troubleshooting](#troubleshooting)

---

## Report

### Setup

| | |
|---|---|
| Service | ECS Fargate, **256 CPU units (0.25 vCPU), 512 MB, 1 task**, us-west-2 |
| Data | 100,000 products generated at startup: name `Product <Brand> <ID>`, category rotated by modulo through 10 names |
| Work per request | Exactly **100 products checked** per search (a rotating window over the catalog), single-threaded, ≤ 20 results returned |
| Load | Locust `FastHttpUser`, 12 common terms (`electronics`, `books`, `alpha`, `product`, …), 0–10 ms wait |
| Load generator | EC2 `t3.medium` in us-west-2, hitting the task's private IP (first attempt: laptop, see [Creative stress testing](#5-creative-stress-testing)) |
| Observability | HW5 Grafana dashboard (Prometheus scrapes the task's `/metrics` every 5 s) **and** CloudWatch `AWS/ECS` service metrics, plus CloudWatch Logs |

**Verification with single searches** (from the EC2 instance, [`results/data/verification_single_search.txt`](results/data/verification_single_search.txt)): ~1.5 ms end to end, ~0.1 ms inside the handler (well under the 20 ms target). Four searches raised `search_products_checked_total` by exactly 400. One user alone already drives the task to ~23% CPU.

### Results

| Test | Users | Duration | Requests | Failures | req/s | p50 | p95 | p99 | CloudWatch CPU (avg) | CloudWatch memory |
|---|---|---|---|---|---|---|---|---|---|---|
| 1: baseline | 5 | 2 min | 85,370 | 0 | 712 | 1 ms | 1 ms | 5 ms | **~77%** | 10.6% (flat) |
| 2: breaking point | 20 | 3 min | 191,421 | 0 | 1,065 | 1 ms | **66 ms** | **87 ms** | **~97–99%** | 10.8% (flat) |
| 3: step load | 1 → 40 | 3.5 min | 144,567 | 0 | 688 | 1 ms | 75 ms | 89 ms | 23% → 100% | flat |

![HW5 Grafana dashboard and CloudWatch side by side across Test 1 and Test 2](results/screenshots/both_tests_side_by_side.png)

### 1. What happened when load increased

- **5 users: moderate CPU, fast responses.** 712 req/s at ~77% CPU, p99 5 ms.
- **20 users: CPU saturated, responses degraded.** 4× the users gave only **1.5× the throughput** (1,065 req/s). CPU sat at 97–99%, and p90/p95/p99 jumped to 62/66/87 ms. Nothing failed; requests got slower.
- **The step test shows where it breaks** ([`test3_step_by_step.csv`](results/data/ec2/test3_step_by_step.csv)):

  | Users | 1 | 2 | 3 | 5 | 10 | 20 | 40 |
  |---|---|---|---|---|---|---|---|
  | req/s | 145 | 296 | 423 | 721 | 892 | 1,069 | 1,151 |
  | CPU | 23% | 38% | 53% | 77% | 95% | 99% | 100% |
  | p95 | 1 ms | 1 ms | 1 ms | 1 ms | 2 ms | 30 ms | 70 ms |

  Throughput grows linearly (~145 req/s per user) until about 5–10 users. After that it flattens at **~1,100–1,150 req/s**, and every extra user only adds latency: going from 20 to 40 users bought 8% more throughput and 2.3× the p95.
- **Why the latency jumps to ~65 ms specifically:** a 0.25 vCPU task gets 25 ms of CPU per 100 ms. Once that's used, Fargate pauses the whole process for the rest of the period. The request logs show it directly: at ~1,000 req/s, consecutive log lines have **~65 ms gaps with nothing in between** ([`request_logs.md`](results/data/request_logs.md)).
- **Memory didn't move:** 10.5–10.8% of 512 MB (~68 MiB RSS) throughout, because all products are loaded at startup.

### 2. Optimization or scaling? The evidence

| Evidence | Where it came from | What it says |
|---|---|---|
| Work per request is constant: products checked/search = **100** in every test | Grafana panel from `search_products_checked_total` | The code isn't doing more work under load |
| Time *inside* the handler is unchanged: p50 0.107 → 0.110 ms, p99 0.26 → 0.39 ms from 5 to 20 users | CloudWatch Logs Insights over every request | The search didn't get slower |
| Client p95 rose 1 → 66 ms while the handler stayed < 0.4 ms | Locust vs. Prometheus/Logs | The extra time is *waiting for CPU*, not computing |
| CPU pinned at 99–100% while throughput plateaus at ~1,100 req/s | CloudWatch CPUUtilization + step test | The task is out of CPU |
| Memory flat at ~10% | CloudWatch MemoryUtilization | Not a memory problem |
| CPU cost per request is roughly constant (~0.09% CPU per req/s at load) | CPU ÷ req/s per step | Capacity scales with CPU, so adding CPU adds throughput |

**Verdict: scaling.** The algorithm is fixed by design (100 checks per search, as with model inference or video frames), and per-request cost doesn't degrade with load. Optimizing constant overhead (JSON encoding, `ToLower` allocations) could raise the ceiling somewhat, but demand grows linearly at ~145 req/s per user, so any fixed ceiling gets hit again. The fix is more CPU: more tasks (horizontal) or a bigger task (vertical).

### 3. Using CloudWatch metrics to make scaling decisions

- **Capacity per task** (from CloudWatch CPU against measured throughput): **~1,100 req/s at 100% CPU**, so ~770 req/s at a 70% target.
- **Demand:** unthrottled, each user sends ~145 req/s. Test 2's 20 users want **~2,900 req/s**.
- **Tasks needed** = demand ÷ capacity at target = 2,900 ÷ 770 ≈ **4 tasks** at 70% CPU (3 would run at ~88%).
- **The trigger:** I created a CloudWatch alarm on the service, `CS6650-search-cpu-high` (average `CPUUtilization` > 70% for one 1-minute period). During the step test it **went into ALARM** on the 18:48 datapoint (96% average, the 10–20 user steps). This is the signal ECS Service Auto Scaling (target tracking on `ECSServiceAverageCPUUtilization` = 70%) uses to add tasks.
- **Reaction time matters:** the alarm fired at 18:51:53, about 4 minutes after CPU crossed 70%, because ECS metrics are 1-minute averages published with a delay. For spiky traffic, scale out at a lower threshold or keep spare capacity rather than relying on the alarm alone.

  ![CloudWatch CPU during the step test with the 70% alarm threshold](results/screenshots/test3_step_cloudwatch_alarm.png)

- **Don't scale on memory:** it stays at ~10%, so memory isn't a useful scaling signal for this service.
- **Caveat:** each task here has its own public IP, so adding tasks only helps once a load balancer spreads traffic across them. That's the next step for horizontal scaling.

### 4. HW5 dashboard vs. CloudWatch, side by side

Same Test 2 window (20 users). Grafana is on the left, CloudWatch on the right:

![Test 2: Grafana and CloudWatch side by side](results/screenshots/test2_20u_side_by_side.png)

| | HW5 Grafana dashboard (Prometheus) | CloudWatch |
|---|---|---|
| **What it showed that the other didn't** | Request rate, error %, **latency percentiles inside the handler**, errors by status, **products checked per search**. This is the app's own view: the search stayed at ~0.1 ms and always checked 100 products. | **CPU and memory relative to the task's Fargate reservation** (0.25 vCPU, 512 MB), measured by the platform rather than my code. Memory at 10% of the limit (Grafana only shows 68 MiB RSS, not how close that is to 512 MB). **Alarms** that can drive auto scaling, and **Logs Insights** over every request. Works without me running anything. |
| Resolution | 5 s: each 30-second step of the step test shows up as its own level | 1 min: the steps blur into one ramp, and data arrives 2–4 min late |
| Blind spots | No idea of the task's limits or the platform. If the laptop running Prometheus is off, nothing is recorded. | No request rate or latency for this service (no load balancer). Can't see *why* CPU is high. |

**Together:** CloudWatch says *the task is out of CPU*; Grafana says *the code isn't any slower, requests are just waiting*. That combination points to scaling rather than optimization. They also cross-check each other: my Grafana CPU panel (from `process_cpu_seconds_total`) reads 77% / 99% for Tests 1 and 2, matching CloudWatch's 77.6% / 98.6%.

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

1. **Same test from two places, to separate client limits from server limits.** The first run was from my laptop. It reached only 43 / 162 req/s at 5 / 20 users, with CPU at 3–7% / 17%. That looks exactly like the handout's *"CPU under 40% with 20 users: checking too few products"*. But the products-checked metric proved 100 per search, and latency was flat at ~110 ms (the laptop → us-west-2 round trip) at both loads. **The load generator was the bottleneck, not the server.** Moving Locust to EC2 in the same region gave 17× the throughput at 5 users and exposed the real CPU limit.

   ![Laptop run: CloudWatch CPU stays under 20% at 20 users](results/screenshots/laptop_test2_20u_cloudwatch_cpu.png)

2. **Step-load shape** (`locust/step_locustfile.py`): 1 → 2 → 3 → 5 → 10 → 20 → 40 users, 30 s each, to find the knee instead of guessing at two points.
3. **A correctness probe built into the service:** `search_products_checked_total`, graphed as products checked per search, rules out "checking too many/too few products" while the test runs.
4. **Log forensics:** Logs Insights percentiles of in-handler time per test, and finding the ~65 ms CPU-throttling gaps in the raw log timeline.
5. **An automated scaling trigger** (the CloudWatch alarm) exercised by real load, not just designed on paper.

### Data

Everything behind the numbers above is in [`results/data/`](results/data):

| File | Contents |
|---|---|
| `ec2/test*_stats.csv`, `ec2/test*_stats_history.csv`, `ec2/test*_locust_report.html`, `ec2/test*_summary.txt` | Locust output for Tests 1–3, with start/end times (UTC) |
| `ec2/test3_step_by_step.csv` | Per-step req/s, latency, CPU, handler p99 |
| `prometheus_timeseries.csv` | 5 s series for all three tests: CPU, RSS, req/s, handler p50/p99, products checked per search |
| `cloudwatch_datapoints.csv` | CloudWatch 1 min CPU and memory (average, maximum) |
| `request_logs.md` | Logs Insights results, CPU-throttling gaps, slow-request lines |
| `verification_single_search.txt` | Single-search checks before load testing |
| `laptop/` | The first (laptop) runs |

---

## Where everything is

```
.
├── src/product-service.go      # handlers (incl. /products/search), product generation, metrics, JSON logs
├── terraform/                  # ECR, ECS (0.25 vCPU / 512 MB / 1 task), security group, log group
├── locust/
│   ├── search_locustfile.py    # Tests 1 and 2: FastHttpUser searching common terms
│   ├── step_locustfile.py      # Test 3: step load 1 → 40 users
│   └── locustfile.py           # HW5 GET/POST mix for the other two endpoints
├── observability/              # Prometheus + Grafana (+ image renderer), HW5 dashboard with CPU/memory/products-checked panels
├── postman/                    # HW5 collection for the other two endpoints
└── results/                    # report screenshots and data
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
   terraform apply        # Plan: 8 to add. Type yes
   ```
   This creates the ECR repo `ecr_search_service`, the cluster `CS6650-search-cluster`, the service `CS6650-search` and the log group `/ecs/CS6650-search`. The names differ from HW5's, so both stacks can run in the same lab account.
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
aws cloudwatch delete-alarms --alarm-names CS6650-search-cpu-high
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
