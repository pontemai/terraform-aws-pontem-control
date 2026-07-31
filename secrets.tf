# Exactly two secrets in Secrets Manager: the database password and the device
# JWT signing key. Both are generated here, so both live in Terraform state —
# treat the state file as secret material and keep it in an encrypted backend.
#
# Deliberately NOT here, even though the internal Pontem stack this is distilled
# from has them:
#
#   * The OIDC issuer and audience. They are public metadata your users'
#     browsers already fetch, and the chart takes them as plain values
#     (auth.oidc.*). Routing non-secrets through Secrets Manager would add two
#     moving parts and buy nothing.
#   * A tracing API key. Control-plane traces on a Pontem-operated stack go to
#     Pontem's own Honeycomb with a shared key; it is not a backend you point at
#     your own account, so a self-hosted stack leaves tracing off.
#
# Per-tenant secrets are not created here either — the application creates those
# at runtime under the tenant-* prefixes, which is what identity.tf grants.

# The API signs device JWTs with this. The control plane's Ed25519 device
# identity provider requires DEVICE_JWT_SIGNING_KEY to be the standard base64
# encoding of EXACTLY 32 bytes and fails at startup on anything else, which is
# why this is a 32-byte random_id rendered as b64_std rather than a
# random_password of some length.
#
# ROTATING THIS INVALIDATES EVERY ENROLLED DEVICE'S JWT. Treat it as permanent.
# There is deliberately no prevent_destroy lifecycle block — that would make
# `terraform destroy` fail outright, which is hostile when someone is tearing
# down an evaluation. The Secrets Manager recovery window
# (secret_recovery_window_days) is the real protection.
resource "random_id" "device_jwt_signing_key" {
  byte_length = 32
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${local.name_prefix}-db-password"
  description             = "RDS Postgres password for pontem-control (DATABASE_PASSWORD)."
  recovery_window_in_days = var.secret_recovery_window_days

  tags = local.tags
}

# random_password.db (rds.tf) is the instance's master password; stored here
# rather than minting a second value that would then have to be kept in sync.
resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db.result
}

resource "aws_secretsmanager_secret" "device_jwt_signing_key" {
  name                    = "${local.name_prefix}-device-jwt-signing-key"
  description             = "Ed25519 device-JWT signing key for pontem-control (DEVICE_JWT_SIGNING_KEY): standard base64 of exactly 32 bytes. Rotating it invalidates every enrolled device's JWT."
  recovery_window_in_days = var.secret_recovery_window_days

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "device_jwt_signing_key" {
  secret_id     = aws_secretsmanager_secret.device_jwt_signing_key.id
  secret_string = random_id.device_jwt_signing_key.b64_std
}
