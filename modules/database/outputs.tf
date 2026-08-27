output "secret_arn" {
  description = "RDS-managed master-user secret (password never written by Terraform)."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "endpoint" { value = aws_db_instance.this.address }
output "port" { value = aws_db_instance.this.port }
output "db_name" { value = aws_db_instance.this.db_name }
output "identifier" { value = aws_db_instance.this.identifier }
