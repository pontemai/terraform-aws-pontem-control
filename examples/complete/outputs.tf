# Re-exported for the install commands in the repo README.

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

output "acm_validation_records" {
  description = "DNS records to create when neither Route53 input is set. Empty otherwise."
  value       = module.pontem_control.acm_validation_records
}

output "route53_name_servers" {
  description = "Name servers for a hosted zone created by the module."
  value       = module.pontem_control.route53_name_servers
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
  description = "Secrets Manager name of the database password."
  value       = module.pontem_control.db_password_secret_name
}

output "device_jwt_signing_key_secret_name" {
  description = "Secrets Manager name of the device JWT signing key."
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
