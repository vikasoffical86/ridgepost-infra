resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.private_subnet_ids
}

# Password never enters Terraform state: RDS creates/manages the SM secret.
resource "aws_db_instance" "this" {
  identifier                   = "${var.name}-db"
  engine                       = "postgres"
  engine_version               = "16"
  instance_class               = "db.t4g.micro"
  allocated_storage            = 20
  storage_type                 = "gp3"
  storage_encrypted            = true
  db_name                      = "ridgepost"
  username                     = "ridgepost"
  manage_master_user_password  = true
  db_subnet_group_name         = aws_db_subnet_group.this.name
  vpc_security_group_ids       = [var.rds_sg_id]
  publicly_accessible          = false
  multi_az                     = false
  backup_retention_period      = 7
  backup_window                = "07:00-08:00"
  maintenance_window           = "sun:08:00-sun:09:00"
  deletion_protection          = true
  skip_final_snapshot          = false
  final_snapshot_identifier    = "${var.name}-db-final"
  copy_tags_to_snapshot        = true
  performance_insights_enabled = false
  apply_immediately            = true

  lifecycle {
    prevent_destroy = true
  }
}
