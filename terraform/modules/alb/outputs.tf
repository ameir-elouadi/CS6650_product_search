output "dns_name" {
  description = "Public DNS name of the ALB"
  value       = aws_lb.this.dns_name
}

output "target_group_arn" {
  description = "Target group the ECS service registers into"
  value       = aws_lb_target_group.this.arn
}

output "arn_suffix" {
  description = "ALB ARN suffix (CloudWatch LoadBalancer dimension)"
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix (CloudWatch TargetGroup dimension)"
  value       = aws_lb_target_group.this.arn_suffix
}
