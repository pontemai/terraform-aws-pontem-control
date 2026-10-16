output "helm_values" {
  description = "Rendered pontem-control chart values for this deployment."
  value = templatefile("${path.module}/templates/values.yaml.tftpl", {
    app_domain_name = var.app_domain_name
    aws_region      = var.aws_region
    certificate_arn = var.acm_certificate_arn
    cluster_name    = var.cluster_name
    alb_scheme      = var.alb_scheme
    alb_subnet_ids  = var.alb_subnet_ids
    route53_zone_id = var.route53_zone_id

    db_password_secret_name            = var.db_password_secret_name
    device_jwt_signing_key_secret_name = var.device_jwt_signing_key_secret_name
    device_secret_pepper_secret_name   = var.device_secret_pepper_secret_name
    device_telemetry_log_group_name    = var.device_telemetry_log_group_name
    device_telemetry_writer_role_arn   = var.device_telemetry_writer_role_arn

    db_host = var.db_host
    db_name = var.db_name
    db_port = var.db_port
    db_user = var.db_user
    # Unset sections and attributes are dropped rather than rendered as null,
    # which the chart's values schema rejects.
    distribution = var.distribution == null ? null : {
      tenants = {
        for tenant, config in var.distribution.tenants : tenant => merge(
          { for key, value in {
            agent = config.agent == null ? null : merge(
              { registryId = config.agent.registryId },
              { for k, v in { allowFallback = config.agent.allowFallback } : k => v if v != null },
            )
          } : key => value if value != null },
          { for key, value in {
            cli = config.cli == null ? null : { registryId = config.cli.registryId }
          } : key => value if value != null },
        )
      }
    }
    oidc_audience  = var.oidc_audience
    oidc_client_id = var.oidc_client_id
    oidc_issuer    = var.oidc_issuer
    wif_audience   = var.wif_audience
  })
}
