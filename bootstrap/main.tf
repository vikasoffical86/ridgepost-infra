data "aws_caller_identity" "me" {}

module "state" {
  source      = "../modules/s3_secure"
  bucket_name = "${var.name}-tfstate-${data.aws_caller_identity.me.account_id}"
  tags        = { Name = "${var.name}-tfstate" }
}

resource "aws_dynamodb_table" "lock" {
  name         = "${var.name}-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  lifecycle { prevent_destroy = true }
}

output "bucket" { value = module.state.bucket_name }
output "lock_table" { value = aws_dynamodb_table.lock.name }
