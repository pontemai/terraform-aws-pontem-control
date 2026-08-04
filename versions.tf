terraform {
  required_version = ">= 1.6.0"

  required_providers {
    # Pinned to a major, not a minimum. A module's constraint is not local: it
    # intersects with the constraints of the caller's root module and every other
    # module they use, and an over-tight pin here means "no available provider
    # matches all constraints" on someone else's `terraform init`. One major is the
    # loosest constraint that still guarantees the attribute names this module uses
    # exist.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# No `kubernetes` / `helm` / `kubectl` providers, and no provider block at all —
# the calling root supplies `provider "aws"`, which is also how the region arrives.
#
# Terraform creates AWS resources and renders Helm values. The Helm release owns
# every in-cluster resource, keeping its lifecycle independent of EKS replacement.
