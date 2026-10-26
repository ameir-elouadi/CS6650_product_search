variable "service_name" {
  type        = string
  description = "Base name for ALB resources"
}

variable "vpc_id" {
  type        = string
  description = "VPC for the target group"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnets the ALB spans"
}

variable "security_group_id" {
  type        = string
  description = "Security group for the ALB"
}

variable "container_port" {
  type        = number
  description = "Port the targets listen on"
}

variable "health_check_path" {
  type        = string
  default     = "/health"
  description = "Path the ALB polls on each target"
}

variable "deregistration_delay" {
  type        = number
  default     = 30
  description = "Seconds to drain a target before removing it"
}
