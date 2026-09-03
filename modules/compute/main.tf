data "aws_caller_identity" "me" {}
data "aws_region" "here" {}

module "assets" {
  source      = "../s3_secure"
  bucket_name = "${var.name}-assets-${data.aws_caller_identity.me.account_id}"
  tags        = { Name = "${var.name}-assets" }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name}-api"
  retention_in_days = 7
}
