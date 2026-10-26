output "policy_name" {
  description = "Target tracking policy name"
  value       = aws_appautoscaling_policy.cpu.name
}

output "alarm_names" {
  description = "CloudWatch alarms the target tracking policy created"
  value       = aws_appautoscaling_policy.cpu.alarm_arns
}
