data "aws_caller_identity" "me" {}
data "aws_region" "here" {}

module "assets" {
  source      = "../s3_secure"
  bucket_name = "${var.name}-assets-${data.aws_caller_identity.me.account_id}"
  tags        = { Name = "${var.name}-assets" }
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "exec" {
  name               = "${var.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "exec" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }
  statement {
    sid       = "PullSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.secret_arn]
  }
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]
    resources = ["arn:aws:ecr:${data.aws_region.here.name}:${data.aws_caller_identity.me.account_id}:repository/${var.name}-api"]
  }
}

resource "aws_iam_role_policy" "exec" {
  name   = "${var.name}-exec-policy"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec.json
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid       = "AssetsList"
    actions   = ["s3:ListBucket"]
    resources = [module.assets.bucket_arn]
  }
  statement {
    sid       = "AssetsRW"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${module.assets.bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${var.name}-task-policy"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name}-api"
  retention_in_days = 7
}

resource "aws_lb" "api" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids
}

# vpc_id from envs/prod module.networking.vpc_id — NOT aws_vpc.this (networking-only resource).
resource "aws_lb_target_group" "api" {
  name        = "${var.name}-api"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"
  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name}-api"
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
    base              = 0
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name}-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name                   = "${var.name}-api"
    image                  = var.container_image
    user                   = "65532"
    essential              = true
    cpu                    = 256
    memory                 = 512
    portMappings           = [{ containerPort = 8080, protocol = "tcp" }]
    readonlyRootFilesystem = true
    linuxParameters        = { initProcessEnabled = true, tmpfs = [{ containerPath = "/tmp", size = 64 }] }
    # Password from RDS-managed SM secret — never from tfvars / random_password in state.
    secrets = [
      { name = "DB_USER", valueFrom = "${var.secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${var.secret_arn}:password::" }
    ]
    environment = [
      { name = "ASSETS_BUCKET", value = module.assets.bucket_name },
      { name = "PORT", value = "8080" },
      { name = "DB_HOST", value = var.db_host },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_PORT", value = tostring(var.db_port) }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = data.aws_region.here.name
        awslogs-stream-prefix = "api"
      }
    }
    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz')\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])
}

resource "aws_ecs_service" "api" {
  name            = "${var.name}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 1
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }
  # On-demand base keeps one always-on task; Spot weight for future scale-out only.
  # Avoids ALB empty target group on Spot reclaim (min_healthy=0 was a silent outage).
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 4
    base              = 0
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "${var.name}-api"
    container_port   = 8080
  }
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  propagate_tags                     = "SERVICE"
  depends_on                         = [aws_lb_listener.https, aws_ecs_cluster_capacity_providers.this]
}

# Scale-out on CPU; min=1 keeps budget baseline (~$9/mo on-demand task).
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-api-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
