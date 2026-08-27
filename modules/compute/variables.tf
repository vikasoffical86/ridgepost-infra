variable "name" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "alb_sg_id" { type = string }
variable "ecs_sg_id" { type = string }
variable "acm_certificate_arn" { type = string }
variable "secret_arn" { type = string }
variable "container_image" { type = string }
variable "db_host" { type = string }
variable "db_name" { type = string }
variable "db_port" {
  type    = number
  default = 5432
}
