# Region to deploy into
variable "aws_region" {
  type    = string
  default = "us-west-2"
}

# ECR & ECS settings
variable "ecr_repository_name" {
  type    = string
  default = "ecr_search_service"
}

variable "service_name" {
  type    = string
  default = "CS6650-search"
}

variable "container_port" {
  type    = number
  default = 8080
}

# Auto scaling (target tracking on average service CPU)
variable "min_tasks" {
  type    = number
  default = 2
}

variable "max_tasks" {
  type    = number
  default = 4
}

variable "cpu_target" {
  type    = number
  default = 70
}

variable "scale_out_cooldown" {
  type    = number
  default = 300
}

variable "scale_in_cooldown" {
  type    = number
  default = 300
}

# Path the ALB health check polls on every task
variable "health_check_path" {
  type    = string
  default = "/health"
}

# How long to keep logs
variable "log_retention_days" {
  type    = number
  default = 7
}
