terraform {
  # The root supplies the AWS provider and region. Terraform creates AWS
  # resources and renders Helm values; the Helm release owns cluster resources.
  required_version = ">= 1.11.4"

  required_providers {
    # Version 6.45 can migrate secret_string to secret_string_wo in place.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.45.0, < 7.0.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}
