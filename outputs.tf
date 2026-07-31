# The chart contract lives in a submodule of pure string rendering so that
# `terraform test` can assert on it without AWS credentials. See
# modules/chart_values.
module "chart_values" {
  source = "./modules/chart_values"

  app_domain_name     = var.app_domain_name
  aws_region          = local.region
  acm_certificate_arn = local.acm_certificate_arn
  namespace           = var.namespace

  db_host = aws_db_instance.this.address
  db_port = aws_db_instance.this.port
  db_name = aws_db_instance.this.db_name
  db_user = aws_db_instance.this.username

  oidc_issuer   = var.oidc_issuer
  oidc_audience = var.oidc_audience
}

# ----- Cluster access -----

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "update_kubeconfig_command" {
  description = "Command that points kubectl at this cluster. Only principals listed in cluster_admin_principal_arns can use the resulting context."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${local.region}"
}

# ----- Network -----

output "vpc_id" {
  description = "ID of the VPC this module created."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs. Internet-facing load balancers land here, discovered by their kubernetes.io/role/elb tag."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs. Nodes run here and the RDS subnet group spans them."
  value       = aws_subnet.private[*].id
}

# ----- Database -----

output "db_endpoint" {
  description = "RDS endpoint hostname, without the port."
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "RDS Postgres port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Application database name."
  value       = aws_db_instance.this.db_name
}

output "db_user" {
  description = "Application database user."
  value       = aws_db_instance.this.username
}

# ----- Secret material for the application's Kubernetes Secret -----

output "db_password" {
  description = "Generated RDS password. Also stored in Secrets Manager (db_password_secret_arn); this output exists so the install can create the Kubernetes Secret without a round trip through the AWS console."
  value       = random_password.db.result
  sensitive   = true
}

output "device_jwt_signing_key" {
  description = "Generated device-JWT signing key, standard base64 of 32 bytes. ROTATING THIS INVALIDATES EVERY ENROLLED DEVICE'S JWT."
  value       = random_id.device_jwt_signing_key.b64_std
  sensitive   = true
}

output "db_password_secret_arn" {
  description = "Secrets Manager ARN of the database password, for the External Secrets Operator path."
  value       = aws_secretsmanager_secret.db_password.arn
}

output "db_password_secret_name" {
  description = "Secrets Manager name of the database password. External Secrets refers to secrets by name, not ARN."
  value       = aws_secretsmanager_secret.db_password.name
}

output "device_jwt_signing_key_secret_arn" {
  description = "Secrets Manager ARN of the device-JWT signing key, for the External Secrets Operator path."
  value       = aws_secretsmanager_secret.device_jwt_signing_key.arn
}

output "device_jwt_signing_key_secret_name" {
  description = "Secrets Manager name of the device-JWT signing key. External Secrets refers to secrets by name, not ARN."
  value       = aws_secretsmanager_secret.device_jwt_signing_key.name
}

# ----- Identity: what Pontem needs from you -----

output "aws_account_id" {
  description = "Account these resources were created in. Pontem pins the federation to this account as well as to the role below, so send both."
  value       = local.account_id
}

output "aws_region" {
  description = "Region these resources were created in, read from the provider. Needed by the External Secrets Operator store, which names its region explicitly."
  value       = local.region
}

output "cp_runtime_role_arn" {
  description = "IAM role ARN the api and worker pods assume via EKS Pod Identity. This is the role's own ARN — the form you use for IAM policies referring to it."
  value       = aws_iam_role.cp_runtime.arn
}

output "cp_runtime_assumed_role_arn" {
  description = "SEND THIS ONE TO PONTEM, together with aws_account_id, to get your gcp.wifAudience. It is the session-stripped assumed-role form (arn:aws:sts::<account>:assumed-role/<role>), which is what GCP Workload Identity Federation exposes as the role attribute and what its trust condition must match. The iam::...:role/... form above will not match and the federation will silently deny."
  value       = "arn:aws:sts::${local.account_id}:assumed-role/${aws_iam_role.cp_runtime.name}"
}

output "external_secrets_role_arn" {
  description = "IAM role ARN for the External Secrets Operator controller, or null when enable_external_secrets_iam is false. Nothing needs it at install time — Pod Identity binds it server-side — but it is here for auditing which role reads the boot secrets."
  value       = var.enable_external_secrets_iam ? aws_iam_role.eso[0].arn : null
}

# ----- DNS and TLS -----

output "acm_certificate_arn" {
  description = "ACM certificate ARN for app_domain_name. When route53_zone_id is set, reading this output implies the certificate is ISSUED."
  value       = local.acm_certificate_arn
}

output "acm_validation_records" {
  description = "DNS validation records to create when route53_zone_id is null, keyed by domain name. The certificate stays PENDING_VALIDATION — and the ALB will never finish attaching it — until these resolve. Empty when the module created them itself."
  value = var.route53_zone_id != null ? {} : {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
}

output "app_url" {
  description = "Where the control plane will answer once the chart is installed and DNS points app_domain_name at the ALB."
  value       = "https://${var.app_domain_name}"
}

# ----- What to hand to Kubernetes -----

output "helm_values" {
  description = "Rendered pontem-control chart values for this deployment. Write it to a file with `terraform output -raw helm_values > values.yaml` and pass it to helm."
  value       = module.chart_values.helm_values
}

output "ingress_class_manifest" {
  description = "The `alb` IngressClass and its IngressClassParams. Apply with `terraform output -raw ingress_class_manifest | kubectl apply -f -`."
  value       = module.chart_values.ingress_class_manifest
}

output "namespace" {
  description = "Namespace to install the chart into. The Pod Identity associations bind service accounts in this namespace, so `helm install -n` must match it."
  value       = var.namespace
}
