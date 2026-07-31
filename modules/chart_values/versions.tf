terraform {
  required_version = ">= 1.6.0"
}

# No required_providers, and no provider is used. That is the point of splitting
# this out: everything here is string rendering, so `terraform test` can plan it
# and assert on the result with no AWS credentials and no network — which is the
# only way the chart contract gets a real automated check before a live apply.
