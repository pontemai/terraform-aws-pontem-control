# Exactly two secrets in Secrets Manager: the database password and the device
# JWT signing key. These random resources are converter-compatible, but their
# values are stored in Terraform state. The write-only AWS arguments below keep
# the values out of the AWS resource state.
#
# Per-tenant secrets are not created here; the application creates those at runtime
# under the tenant-* prefixes that identity.tf grants.

# The API signs device JWTs with this. The control plane's Ed25519 device
# identity provider requires DEVICE_JWT_SIGNING_KEY to be the standard base64
# encoding of EXACTLY 32 bytes and fails at startup on anything else, which is
# why this is 32 random bytes rendered as standard base64 rather than a password
# of some length.
#
# Rotation invalidates every enrolled device's JWT.
# There is deliberately no prevent_destroy lifecycle block — that would make
# `terraform destroy` fail outright, which is hostile when someone is tearing
# down an evaluation. The Secrets Manager recovery window
# (secret_recovery_window_days) is the real protection.
resource "random_password" "db" {
  length  = 32
  special = false

  keepers = {
    version = var.db_password_version
  }
}

resource "random_bytes" "device_jwt_signing_key" {
  length = 32

  keepers = {
    version = var.device_jwt_signing_key_version
  }
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.name_prefix}-db-password"
  description             = "RDS Postgres password for pontem-control (DATABASE_PASSWORD)."
  recovery_window_in_days = var.secret_recovery_window_days

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id                = aws_secretsmanager_secret.db_password.id
  secret_string_wo         = random_password.db.result
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
  secret_string_wo         = random_bytes.device_jwt_signing_key.base64
  secret_string_wo_version = var.device_jwt_signing_key_version
}
