locals {
  # The admin app is configured with the identity provider's HOST, not its issuer
  # URL, and rebuilds "https://<host>/" from it. trimprefix and trimsuffix rather
  # than replace(): replace would strip a slash from anywhere in the string, so a
  # value the caller's validation should have rejected would be silently mangled
  # into a plausible-looking host instead of failing.
  oidc_domain = trimsuffix(trimprefix(lower(var.oidc_issuer), "https://"), "/")
}

output "helm_values" {
  description = "Rendered pontem-control chart values for this deployment."
  value = templatefile("${path.module}/templates/values.yaml.tftpl", {
    app_domain_name = var.app_domain_name
    aws_region      = var.aws_region
    certificate_arn = var.acm_certificate_arn
    cluster_name    = var.cluster_name
    route53_zone_id = var.route53_zone_id

    db_password_secret_name            = var.db_password_secret_name
    device_jwt_signing_key_secret_name = var.device_jwt_signing_key_secret_name

    db_host        = var.db_host
    db_name        = var.db_name
    db_port        = var.db_port
    db_user        = var.db_user
    oidc_audience  = var.oidc_audience
    oidc_client_id = var.oidc_client_id
    oidc_domain    = local.oidc_domain
    oidc_issuer    = var.oidc_issuer
    wif_audience   = var.wif_audience
  })
}
