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
    device_telemetry_log_group_name    = var.device_telemetry_log_group_name
    device_telemetry_writer_role_arn   = var.device_telemetry_writer_role_arn

    db_host = var.db_host
    db_name = var.db_name
    db_port = var.db_port
    db_user = var.db_user
    distribution = var.distribution == null ? null : {
      tenants = merge(
        {
          for tenant, config in var.distribution.tenants : tenant => {
            agent = merge(
              { registryId = config.agent.registryId },
              { for key, value in { allowFallback = config.agent.allowFallback } : key => value if value != null },
            )
          } if config.agent != null
        },
        { for tenant, config in var.distribution.tenants : tenant => {} if config.agent == null },
      )
    }
    oidc_audience  = var.oidc_audience
    oidc_client_id = var.oidc_client_id
    oidc_issuer    = var.oidc_issuer
    wif_audience   = var.wif_audience
  })
}
