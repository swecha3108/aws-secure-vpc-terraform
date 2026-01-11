terraform {
  backend "s3" {
    bucket         = "swecha-terraform-state-aws-secure-vpc"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
