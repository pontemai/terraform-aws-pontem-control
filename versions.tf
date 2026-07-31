terraform {
  required_version = ">= 1.6.0"

  required_providers {
    # Pinned to a major, not a minimum. A module's constraint is not local: it
    # intersects with the constraints of the caller's root module and every other
    # module they use, and an over-tight pin here means "no available provider
    # matches all constraints" on someone else's `terraform init`. One major is the
    # loosest constraint that still guarantees the attribute names below exist.
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

# Deliberately no `kubernetes` / `helm` / `kubectl` providers, and no provider
# block at all — the calling root supplies `provider "aws"`, which is also how
# the region arrives.
#
# The two in-cluster objects this module would otherwise create (the
# pontem-control Secret and the `alb` IngressClass) are emitted as outputs you
# apply with kubectl. That is not squeamishness about mixing providers: a
# Kubernetes-flavoured provider must be configured from the cluster's endpoint,
# and if the cluster ever plans a REPLACEMENT that endpoint is unknown at plan
# time, so the provider errors before it can tell you why. Recovering means
# `terraform state rm` on the in-cluster resources, applying the cluster, then
# re-applying. That is a bad afternoon for us and an impossible one for someone
# running this in an account we cannot see.
