terraform {
  required_version = ">= 1.10"

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
  region = var.region

  # No profile here. Locally, set AWS_PROFILE in your shell:
  #   export AWS_PROFILE=retail-dev
  # In CI, credentials come from the assumed role via the standard chain.
  # Hardcoding a profile works on one laptop and breaks everywhere else.

  default_tags {
    tags = {
      Project   = "retail-data-platform"
      ManagedBy = "terraform"
      Owner     = "data-platform"
    }
  }
}
