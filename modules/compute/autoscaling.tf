# Scale-out on CPU; min=1 keeps budget baseline (~$9/mo on-demand task).
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 5
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

# Weekday 9–17 UTC burst to 5 tasks; off-peak max=1 keeps FARGATE base only.
resource "aws_appautoscaling_scheduled_action" "peak_up" {
  name               = "${var.name}-peak-up"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  schedule           = "cron(0 9 ? * MON-FRI *)"
  scalable_target_action {
    min_capacity = 1
    max_capacity = 5
  }
}

resource "aws_appautoscaling_scheduled_action" "peak_down" {
  name               = "${var.name}-peak-down"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  schedule           = "cron(0 17 ? * MON-FRI *)"
  scalable_target_action {
    min_capacity = 1
    max_capacity = 1
  }
}
