variable "service_name" {
  type        = string
  description = "ECS service name"
}

variable "cluster_name" {
  type        = string
  description = "ECS cluster name"
}

variable "alb_arn_suffix" {
  type        = string
  description = "ALB ARN suffix (LoadBalancer dimension)"
}

variable "target_group_arn_suffix" {
  type        = string
  description = "Target group ARN suffix (TargetGroup dimension)"
}

variable "alarm_arns" {
  type        = list(string)
  description = "Alarms to show (the target tracking policy's)"
}

variable "cpu_target" {
  type        = number
  description = "Scaling target, drawn on the CPU graph"
}

variable "region" {
  type        = string
  description = "AWS region"
}
