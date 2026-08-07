data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  # Modules cannot set provider default_tags, so each resource gets this map.
  tags = merge({
    Project   = "pontem-control"
    ManagedBy = "terraform"
  }, var.tags)

  # name_prefix validation keeps boot secrets outside these runtime-role grants.
  tenant_secret_arns = [
    "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:tenant-*",
    "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:registry-tenant-*",
  ]

  # Resource counts need a plan-time value; a new zone's ID stays unknown until apply.
  has_route53_zone = var.create_route53_zone || var.route53_zone_id != null

  # Callers use this only as a value, where an unknown ID is safe during planning.
  route53_zone_id = var.create_route53_zone ? aws_route53_zone.this[0].zone_id : var.route53_zone_id
}
