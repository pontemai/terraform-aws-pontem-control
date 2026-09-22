# Three boot secrets: database password, device JWT signing key, and device
# secret pepper. Their values are ephemeral and flow only through write-only
# provider arguments, so Terraform never stores them in plans or state.
#
# Per-tenant secrets are not created here; the application creates those at runtime
# under the tenant-* prefixes that identity.tf grants.

# The recovery window protects against accidental deletion while still allowing
# evaluation stacks to be destroyed without a prevent_destroy lifecycle block.
ephemeral "random_password" "db" {
  length  = 32
  special = false
}

# Ed25519 requires standard base64 of exactly 32 bytes. Rotation invalidates
# every enrolled device's JWT.
ephemeral "random_bytes" "device_jwt_signing_key" {
  length = 32
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.name_prefix}-db-password"
  description             = "RDS Postgres password for pontem-control (DATABASE_PASSWORD)."
  recovery_window_in_days = var.secret_recovery_window_days

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id                = aws_secretsmanager_secret.db_password.id
  secret_string_wo         = ephemeral.random_password.db.result
  secret_string_wo_version = var.db_password_version
}

resource "aws_secretsmanager_secret" "device_jwt_signing_key" {
  name                    = "${var.name_prefix}-device-jwt-signing-key"
  description             = "Ed25519 device-JWT signing key for pontem-control (DEVICE_JWT_SIGNING_KEY): standard base64 of exactly 32 bytes. Rotating it invalidates every enrolled device's JWT."
  recovery_window_in_days = var.secret_recovery_window_days

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "device_jwt_signing_key" {
  secret_id                = aws_secretsmanager_secret.device_jwt_signing_key.id
  secret_string_wo         = ephemeral.random_bytes.device_jwt_signing_key.base64
  secret_string_wo_version = var.device_jwt_signing_key_version
}

locals {
  create_device_secret_pepper = var.existing_device_secret_pepper_secret_arn == null
  device_secret_pepper_secret = {
    arn  = local.create_device_secret_pepper ? aws_secretsmanager_secret.device_secret_pepper[0].arn : var.existing_device_secret_pepper_secret_arn
    name = local.create_device_secret_pepper ? aws_secretsmanager_secret.device_secret_pepper[0].name : data.aws_secretsmanager_secret.device_secret_pepper[0].name
  }
}

# Metadata only: the caller owns the existing value and its rotation.
data "aws_secretsmanager_secret" "device_secret_pepper" {
  count = local.create_device_secret_pepper ? 0 : 1
  arn   = var.existing_device_secret_pepper_secret_arn
}

moved {
  from = aws_secretsmanager_secret.device_secret_pepper
  to   = aws_secretsmanager_secret.device_secret_pepper[0]
}

moved {
  from = aws_secretsmanager_secret_version.device_secret_pepper
  to   = aws_secretsmanager_secret_version.device_secret_pepper[0]
}

ephemeral "random_bytes" "device_secret_pepper" {
  count  = local.create_device_secret_pepper ? 1 : 0
  length = 32
}

resource "aws_secretsmanager_secret" "device_secret_pepper" {
  count = local.create_device_secret_pepper ? 1 : 0

  name                    = "${var.name_prefix}-device-secret-pepper"
  description             = "Device secret cache pepper for pontem-control (DEVICE_SECRET_PEPPER): standard base64 of exactly 32 bytes."
  recovery_window_in_days = var.secret_recovery_window_days

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "device_secret_pepper" {
  count = local.create_device_secret_pepper ? 1 : 0

  secret_id                = aws_secretsmanager_secret.device_secret_pepper[0].id
  secret_string_wo         = ephemeral.random_bytes.device_secret_pepper[0].base64
  secret_string_wo_version = var.device_secret_pepper_version
}
