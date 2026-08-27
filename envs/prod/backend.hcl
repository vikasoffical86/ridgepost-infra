bucket         = "ridgepost-tfstate-REPLACE_ACCOUNT"
key            = "ridgepost/prod/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "ridgepost-tf-lock"
encrypt        = true
