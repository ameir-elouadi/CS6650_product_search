# One CloudWatch dashboard for the scaling experiments: infra (tasks, CPU) and ALB (requests, latency, health)
locals {
  ecs = ["ClusterName", var.cluster_name, "ServiceName", var.service_name]
  lb  = ["LoadBalancer", var.alb_arn_suffix]
  tg  = ["TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix]

  widgets = [
    {
      title = "ECS service CPU (average and hottest task)", x = 0, y = 0,
      metrics = [
        concat(["AWS/ECS", "CPUUtilization"], local.ecs, [{ stat = "Average", label = "Average" }]),
        concat(["AWS/ECS", "CPUUtilization"], local.ecs, [{ stat = "Maximum", label = "Maximum" }]),
      ],
      yAxis       = { left = { min = 0, max = 100 } },
      annotations = { horizontal = [{ value = var.cpu_target, label = "Scaling target" }] },
    },
    {
      title = "CPU per task (% of 0.25 vCPU)", x = 12, y = 0,
      metrics = [
        [{ expression = "SEARCH('{ECS/ContainerInsights,ClusterName,TaskDefinitionFamily,TaskId} MetricName=\"CpuUtilized\" ClusterName=\"${var.cluster_name}\"', 'Average', 60) / 2.56", id = "pertask", label = "" }],
      ],
      yAxis = { left = { min = 0, max = 100 } },
    },
    {
      title = "Tasks: desired vs running vs pending", x = 0, y = 6,
      metrics = [
        concat(["ECS/ContainerInsights", "DesiredTaskCount"], local.ecs, [{ label = "Desired" }]),
        concat(["ECS/ContainerInsights", "RunningTaskCount"], local.ecs, [{ label = "Running" }]),
        concat(["ECS/ContainerInsights", "PendingTaskCount"], local.ecs, [{ label = "Pending" }]),
      ],
      yAxis = { left = { min = 0, max = 5 } },
    },
    {
      title = "Target group: healthy vs unhealthy targets", x = 12, y = 6,
      metrics = [
        concat(["AWS/ApplicationELB", "HealthyHostCount"], local.tg, [{ stat = "Minimum", label = "Healthy (min)" }]),
        concat(["AWS/ApplicationELB", "UnHealthyHostCount"], local.tg, [{ stat = "Maximum", label = "Unhealthy (max)" }]),
      ],
      yAxis = { left = { min = 0, max = 5 } },
    },
    {
      title = "ALB requests per minute", x = 0, y = 12,
      metrics = [
        concat(["AWS/ApplicationELB", "RequestCount"], local.lb, [{ stat = "Sum", label = "Requests" }]),
        concat(["AWS/ApplicationELB", "RequestCountPerTarget"], local.tg, [{ stat = "Sum", label = "Per target", yAxis = "right" }]),
      ],
    },
    {
      title = "ALB target response time", x = 12, y = 12,
      metrics = [
        concat(["AWS/ApplicationELB", "TargetResponseTime"], local.lb, [{ stat = "Average", label = "Average" }]),
        concat(["AWS/ApplicationELB", "TargetResponseTime"], local.lb, [{ stat = "p95", label = "p95" }]),
        concat(["AWS/ApplicationELB", "TargetResponseTime"], local.lb, [{ stat = "p99", label = "p99" }]),
      ],
    },
    {
      title = "Errors (count per minute)", x = 0, y = 18,
      metrics = [
        concat(["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count"], local.lb, [{ stat = "Sum", label = "Target 5XX" }]),
        concat(["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count"], local.lb, [{ stat = "Sum", label = "ALB 5XX (no healthy/reachable target)" }]),
        concat(["AWS/ApplicationELB", "TargetConnectionErrorCount"], local.lb, [{ stat = "Sum", label = "Target connection errors" }]),
      ],
    },
    {
      title = "ECS service memory", x = 12, y = 18,
      metrics = [
        concat(["AWS/ECS", "MemoryUtilization"], local.ecs, [{ stat = "Average", label = "Average" }]),
      ],
      yAxis = { left = { min = 0, max = 100 } },
    },
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.service_name}-scaling"
  dashboard_body = jsonencode({
    start          = "-PT1H"
    periodOverride = "inherit"
    widgets = concat(
      [for w in local.widgets : {
        type = "metric", x = w.x, y = w.y, width = 12, height = 6
        properties = merge(
          { title = w.title, region = var.region, view = "timeSeries", stacked = false, period = 60, metrics = w.metrics },
          try({ yAxis = w.yAxis }, {}),
          try({ annotations = w.annotations }, {}),
        )
      }],
      [{
        type       = "alarm", x = 0, y = 24, width = 24, height = 2
        properties = { title = "Target tracking alarms (scale out / scale in)", alarms = var.alarm_arns }
      }],
    )
  })
}
