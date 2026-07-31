terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

# No backend block. State for this stack contains the database password and the
# device JWT signing key, so it belongs in encrypted remote storage with locking —
# but which one is your decision, not this module's. The README has the shape of
# the usual S3 + DynamoDB answer.
