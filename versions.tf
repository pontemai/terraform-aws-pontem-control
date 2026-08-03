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
# The `alb` IngressClass is emitted as a manifest output to apply with kubectl; the
# pontem-control Secret is assembled from two value outputs by `kubectl create
# secret` (see the README). Neither is a Terraform resource because a
# Kubernetes-flavoured provider must be configured from the cluster endpoint, which
# is unknown at plan time whenever the cluster plans a REPLACEMENT — the provider
# then errors before it can say why, and recovery is `terraform state rm` on the
# in-cluster resources, apply the cluster, re-apply.
