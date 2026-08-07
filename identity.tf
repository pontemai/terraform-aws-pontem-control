# Auto Mode includes the EKS Pod Identity agent. Associations match the chart's
# service-account names and install namespace; a mismatch starts pods without AWS
# credentials. The chart uses the bare names "api" and "worker".

# ----- Control-plane runtime role -----

# One role supplies tenant-secret access and the AWS identity used for GCP federation.

locals {
  pod_identity_assume_role_policies = {
    for role, service_accounts in {
      cp_runtime   = var.pod_identity_service_accounts
      eso          = ["external-secrets"]
      external_dns = ["external-dns"]
      } : role => jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect = "Allow"
          Principal = {
            Service = "pods.eks.amazonaws.com"
          }
          # Pod Identity requires TagSession because the agent supplies the
          # cluster, namespace, and service-account tags checked below.
          Action = ["sts:AssumeRole", "sts:TagSession"]
          Condition = {
            StringEquals = merge({
              "aws:RequestTag/eks-cluster-arn"            = ["arn:aws:eks:${local.region}:${local.account_id}:cluster/${var.name_prefix}"]
              "aws:RequestTag/kubernetes-namespace"       = [var.namespace]
              "aws:RequestTag/kubernetes-service-account" = service_accounts
              "aws:SourceAccount"                         = [local.account_id]
              }, var.aws_organization_id == null ? {} : {
              "aws:SourceOrgId" = [var.aws_organization_id]
            })
          }
        }]
    })
  }
}

resource "aws_iam_role" "cp_runtime" {
  name               = "${var.name_prefix}-cp-runtime"
  description        = "Runtime identity for the pontem-control api/worker pods in ${var.name_prefix}, assumed via EKS Pod Identity: tenant-secret CRUD in Secrets Manager, and the AWS identity Pontem's GCP Workload Identity Federation provider trusts."
  assume_role_policy = local.pod_identity_assume_role_policies.cp_runtime

  tags = local.tags
}

data "aws_iam_policy_document" "cp_runtime" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
      "secretsmanager:UpdateSecretVersionStage",
      "secretsmanager:TagResource",
    ]
    resources = local.tenant_secret_arns
  }
}

resource "aws_iam_role_policy" "cp_runtime" {
  name   = "${var.name_prefix}-cp-runtime"
  role   = aws_iam_role.cp_runtime.id
  policy = data.aws_iam_policy_document.cp_runtime.json
}

# Associations can be created before the chart creates its service accounts.
resource "aws_eks_pod_identity_association" "cp_runtime" {
  for_each = toset(var.pod_identity_service_accounts)

  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.namespace
  service_account = each.value
  role_arn        = aws_iam_role.cp_runtime.arn

  tags = local.tags
}

# ----- External Secrets Operator role -----

moved {
  from = aws_iam_role.eso[0]
  to   = aws_iam_role.eso
}

moved {
  from = aws_iam_role_policy.eso[0]
  to   = aws_iam_role_policy.eso
}

moved {
  from = aws_eks_pod_identity_association.eso[0]
  to   = aws_eks_pod_identity_association.eso
}

resource "aws_iam_role" "eso" {
  name               = "${var.name_prefix}-external-secrets"
  description        = "External Secrets Operator controller in ${var.name_prefix}, assumed via EKS Pod Identity. Read-only on this module's two boot secrets."
  assume_role_policy = local.pod_identity_assume_role_policies.eso

  tags = local.tags
}

resource "aws_iam_role_policy" "eso" {
  name = "${var.name_prefix}-external-secrets"
  role = aws_iam_role.eso.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = [
        aws_secretsmanager_secret.db_password.arn,
        aws_secretsmanager_secret.device_jwt_signing_key.arn,
      ]
    }]
  })
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.namespace
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn

  tags = local.tags
}

# ----- ExternalDNS role -----

resource "aws_iam_role" "external_dns" {
  count = local.has_route53_zone ? 1 : 0

  name               = "${var.name_prefix}-external-dns"
  description        = "ExternalDNS controller in ${var.name_prefix}, assumed via EKS Pod Identity. DNS changes are limited to ${var.app_domain_name}."
  assume_role_policy = local.pod_identity_assume_role_policies.external_dns

  tags = local.tags
}

resource "aws_iam_role_policy" "external_dns" {
  count = local.has_route53_zone ? 1 : 0

  name = "${var.name_prefix}-external-dns"
  role = aws_iam_role.external_dns[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = ["arn:aws:route53:::hostedzone/${local.route53_zone_id}"]
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsActions" = ["CREATE", "UPSERT", "DELETE"]
            # The chart keeps ownership records below an app-domain zone apex.
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [
              var.app_domain_name,
              "external-dns-a.${var.app_domain_name}",
              "external-dns-aaaa.${var.app_domain_name}",
              "external-dns-cname.${var.app_domain_name}",
            ]
            "route53:ChangeResourceRecordSetsRecordTypes" = ["A", "AAAA", "CNAME", "TXT"]
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListResourceRecordSets"]
        Resource = ["arn:aws:route53:::hostedzone/${local.route53_zone_id}"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones"]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_dns" {
  count = local.has_route53_zone ? 1 : 0

  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.namespace
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns[0].arn

  tags = local.tags
}
