output "helm_values" {
  description = "Rendered pontem-control chart values for this deployment."
  value = templatefile("${path.module}/templates/values.yaml.tftpl", {
    app_domain_name         = var.app_domain_name
    aws_region              = var.aws_region
    credentials_secret_name = var.credentials_secret_name
    db_host                 = var.db_host
    db_name                 = var.db_name
    db_port                 = var.db_port
    db_user                 = var.db_user
    oidc_audience           = var.oidc_audience
    oidc_issuer             = var.oidc_issuer
    wif_audience            = var.wif_audience
  })
}

output "ingress_class_manifest" {
  description = "The `alb` IngressClass and its IngressClassParams, as a manifest to apply with kubectl."
  value = templatefile("${path.module}/templates/ingressclass.yaml.tftpl", {
    acm_certificate_arn = var.acm_certificate_arn
  })
}

output "namespace" {
  description = "Namespace the install targets. Echoed back so callers rendering install commands read it from one place."
  value       = var.namespace
}
