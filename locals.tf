data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  # Tags are merged onto each resource individually rather than relying on the
  # provider's default_tags: the provider block belongs to the caller, and a
  # module that only works when its caller remembered to set default_tags is a
  # module that silently produces untagged resources.
  tags = merge({
    Project   = "pontem-control"
    ManagedBy = "terraform"
  }, var.tags)

  # The two tenant-secret name prefixes the control plane's secret store writes
  # under: user secrets as tenant-{tenant}-{id}, registry credentials as
  # registry-tenant-{tenant}-{id}. Both must be listed — "registry-tenant-*" is
  # NOT covered by "tenant-*", because the leading token differs. name_prefix is
  # validated not to start with either token, so this module's own boot secrets
  # fall outside both — which is what keeps the runtime role off the database
  # password and the device signing key.
  tenant_secret_arns = [
    "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:tenant-*",
    "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:registry-tenant-*",
  ]
}
