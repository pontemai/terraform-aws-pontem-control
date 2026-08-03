variable "app_domain_name" {
  description = "Hostname the control plane is served at; becomes ingress.domain."
  type        = string
}

variable "aws_region" {
  description = "Region the pods run in; becomes aws.region, used by the AWS secrets backend and the GCP federation."
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for app_domain_name, attached by the IngressClassParams rather than by a chart annotation."
  type        = string
}

variable "db_host" {
  description = "RDS endpoint hostname, no port."
  type        = string
}

variable "db_port" {
  description = "RDS Postgres port."
  type        = number
}

variable "db_name" {
  description = "Application database name."
  type        = string
}

variable "db_user" {
  description = "Application database user."
  type        = string
}

variable "oidc_issuer" {
  description = "OIDC issuer URL, rendered as auth.oidc.issuer for the API's token validation. The admin app is configured with the host on its own, which is derived from this."
  type        = string
}

variable "oidc_audience" {
  description = "OIDC API audience, rendered as both auth.oidc.audience (the API's validation) and admin.auth0.audience (what the browser requests tokens for). One value, two consumers — they have to agree."
  type        = string
}

variable "oidc_client_id" {
  description = "Public SPA client ID, rendered as admin.auth0.clientId. Browser-only."
  type        = string
}

variable "wif_audience" {
  description = "GCP Workload Identity Federation audience, rendered as gcp.wifAudience."
  type        = string
}
