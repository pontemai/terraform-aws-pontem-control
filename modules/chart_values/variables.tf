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

variable "credentials_secret_name" {
  description = "Name of the Kubernetes Secret holding the application's secret environment; becomes credentials.existingSecret.name."
  type        = string
  default     = "pontem-control"
}

variable "oidc_issuer" {
  description = "OIDC issuer URL, rendered as auth.oidc.issuer for the API's token validation."
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

variable "oidc_domain" {
  description = "Identity provider host with no scheme, e.g. \"your-tenant.us.auth0.com\", rendered as admin.auth0.domain. The admin container rebuilds \"https://<host>/\" from it, so a scheme here would produce a doubled one."
  type        = string
}

variable "wif_audience" {
  description = "GCP Workload Identity Federation audience, rendered as gcp.wifAudience. Pontem issues this per customer once the AWS account and the control-plane runtime role ARN are known, so the default is a deliberately loud placeholder rather than an empty string — the chart refuses to install with it unset, and a sentinel is easier to spot in a diff than a blank."
  type        = string
  default     = "REPLACE_ME_PONTEM_SUPPLIED"
}
