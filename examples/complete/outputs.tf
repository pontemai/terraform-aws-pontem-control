# Re-exported so the install commands in the README can read them from this root
# with `terraform output`. The VPC id, the subnet ids, and the RDS endpoint stay in
# the module — nothing in the install needs them.

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.pontem_control.cluster_name
}

output "update_kubeconfig_command" {
  description = "Points kubectl at the new cluster."
  value       = module.pontem_control.update_kubeconfig_command
}

output "namespace" {
  description = "Namespace to install the chart into."
  value       = module.pontem_control.namespace
}

output "helm_values" {
  description = "Chart values for this deployment."
  value       = module.pontem_control.helm_values
}

output "ingress_class_manifest" {
  description = "The alb IngressClass and its parameters, to apply with kubectl."
  value       = module.pontem_control.ingress_class_manifest
}

output "db_password" {
  description = "Database password, for the application Secret."
  value       = module.pontem_control.db_password
  sensitive   = true
}

output "device_jwt_signing_key" {
  description = "Device JWT signing key, for the application Secret."
  value       = module.pontem_control.device_jwt_signing_key
  sensitive   = true
}

output "acm_validation_records" {
  description = "DNS records to create by hand when route53_zone_id is not set. Empty otherwise."
  value       = module.pontem_control.acm_validation_records
}

output "app_url" {
  description = "Where the control plane will answer once DNS points at the load balancer."
  value       = module.pontem_control.app_url
}

# The two values to send Pontem to get your gcp.wifAudience.
output "aws_account_id" {
  description = "Account these resources live in."
  value       = module.pontem_control.aws_account_id
}

output "aws_region" {
  description = "Region these resources live in."
  value       = module.pontem_control.aws_region
}

output "db_password_secret_name" {
  description = "Secrets Manager name of the database password, for the External Secrets path."
  value       = module.pontem_control.db_password_secret_name
}

output "device_jwt_signing_key_secret_name" {
  description = "Secrets Manager name of the device JWT signing key, for the External Secrets path."
  value       = module.pontem_control.device_jwt_signing_key_secret_name
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN, for checking issuance status."
  value       = module.pontem_control.acm_certificate_arn
}

output "cp_runtime_assumed_role_arn" {
  description = "Session-stripped assumed-role ARN of the control-plane runtime role. Send this and aws_account_id to Pontem."
  value       = module.pontem_control.cp_runtime_assumed_role_arn
}
