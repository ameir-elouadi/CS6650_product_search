output "ecs_cluster_name" {
  description = "Name of the created ECS cluster"
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "Name of the running ECS service"
  value       = module.ecs.service_name
}

output "aws_region" {
  description = "Region the service is deployed in"
  value       = var.aws_region
}

output "alb_dns_name" {
  description = "Send traffic here: http://<alb_dns_name>/products/search?q=..."
  value       = module.alb.dns_name
}

output "dashboard_url" {
  description = "CloudWatch dashboard for the scaling experiments"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${module.monitoring.dashboard_name}"
}
