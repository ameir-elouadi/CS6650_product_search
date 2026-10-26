# Wire together focused modules: network, ecr, logging, alb, ecs, autoscaling, monitoring.

module "network" {
  source         = "./modules/network"
  service_name   = var.service_name
  container_port = var.container_port
}

module "ecr" {
  source          = "./modules/ecr"
  repository_name = var.ecr_repository_name
}

module "logging" {
  source            = "./modules/logging"
  service_name      = var.service_name
  retention_in_days = var.log_retention_days
}

module "alb" {
  source            = "./modules/alb"
  service_name      = var.service_name
  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.subnet_ids
  security_group_id = module.network.alb_security_group_id
  container_port    = var.container_port
  health_check_path = var.health_check_path
}

# Reuse an existing IAM role for ECS tasks
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

module "ecs" {
  source             = "./modules/ecs"
  service_name       = var.service_name
  image              = "${module.ecr.repository_url}:latest"
  container_port     = var.container_port
  subnet_ids         = module.network.subnet_ids
  security_group_ids = [module.network.security_group_id]
  execution_role_arn = data.aws_iam_role.lab_role.arn
  task_role_arn      = data.aws_iam_role.lab_role.arn
  log_group_name     = module.logging.log_group_name
  ecs_count          = var.min_tasks
  region             = var.aws_region
  target_group_arn   = module.alb.target_group_arn

  # Start the service only after the image is in ECR
  depends_on = [docker_registry_image.app]
}

module "autoscaling" {
  source             = "./modules/autoscaling"
  cluster_name       = module.ecs.cluster_name
  service_name       = module.ecs.service_name
  min_tasks          = var.min_tasks
  max_tasks          = var.max_tasks
  cpu_target         = var.cpu_target
  scale_out_cooldown = var.scale_out_cooldown
  scale_in_cooldown  = var.scale_in_cooldown
}

module "monitoring" {
  source                  = "./modules/monitoring"
  service_name            = var.service_name
  cluster_name            = module.ecs.cluster_name
  alb_arn_suffix          = module.alb.arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  alarm_arns              = module.autoscaling.alarm_names
  cpu_target              = var.cpu_target
  region                  = var.aws_region
}


// Build & push the Go app image into ECR
resource "docker_image" "app" {
  # Use the URL from the ecr module, and tag it "latest"
  name = "${module.ecr.repository_url}:latest"

  build {
    # relative path from terraform/ → src/
    context = "../src"
    # Dockerfile defaults to "Dockerfile" in that context
  }
}

resource "docker_registry_image" "app" {
  # this will push :latest → ECR
  name = docker_image.app.name
}
