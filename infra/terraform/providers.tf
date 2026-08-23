terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }


  
   backend "s3" {
     bucket       = "sd-retail-tfstate-009073574996-eu-west-2-an"
     key          = "platform/terraform.tfstate"
     region       = "eu-west-2"
     encrypt      = true
     use_lockfile = true   # native S3 locking — no DynamoDB table needed
   }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  # Every resource gets these. Cost allocation by tag is what makes the
  # cost/performance case study possible later.
  default_tags {
    tags = {
      Project   = "retail-data-platform"
      ManagedBy = "terraform"
      Owner     = "data-platform"
    }
  }
}
