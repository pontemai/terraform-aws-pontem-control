data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  name_prefix  = var.name_prefix
  cluster_name = var.name_prefix

  # The admin app is configured with the identity provider's HOST, not its issuer
  # URL — its container builds "https://<host>/" back up itself. The validation on
  # oidc_issuer guarantees no path, so stripping the scheme and trailing slash is
  # exact rather than a best guess.
  oidc_domain = replace(replace(var.oidc_issuer, "https://", ""), "/", "")

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
  # NOT covered by "tenant-*", because the leading token differs. Neither
  # matches this module's own ${name_prefix}-* boot secrets, which is what keeps
  # the runtime role unable to read the database password.
  tenant_secret_arns = [
    "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:tenant-*",
    "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:registry-tenant-*",
  ]
}
