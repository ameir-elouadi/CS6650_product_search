variable "cluster_name" {
  type        = string
  description = "ECS cluster name"
}

variable "service_name" {
  type        = string
  description = "ECS service name"
}

variable "min_tasks" {
  type        = number
  description = "Minimum task count"
}

variable "max_tasks" {
  type        = number
  description = "Maximum task count"
}

variable "cpu_target" {
  type        = number
  description = "Average CPU utilization (%) to hold"
}

variable "scale_out_cooldown" {
  type        = number
  description = "Seconds after a scale-out before another scale-out"
}

variable "scale_in_cooldown" {
  type        = number
  description = "Seconds after a scale-in before another scale-in"
}
