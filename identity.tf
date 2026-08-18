# Auto Mode includes the EKS Pod Identity agent. Associations match the chart's
# service-account names and install namespace; a mismatch starts pods without AWS
# credentials. The chart uses the bare names "api", "worker", and optional "mcp".

# ----- Control-plane runtime role -----

# One role supplies tenant-secret and telemetry access plus the AWS identity used
# for GCP federation. Session-tag conditions keep workload permissions separate.

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
  description        = "Runtime identity for the pontem-control api, worker, and optional mcp pods in ${var.name_prefix}, assumed via EKS Pod Identity."
  assume_role_policy = local.pod_identity_assume_role_policies.cp_runtime

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "device_telemetry" {
  name              = "/${var.name_prefix}/device"
  retention_in_days = var.cloudwatch_log_retention_days

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

  statement {
    effect = "Allow"
    actions = [
      "logs:StartQuery",
      "logs:GetQueryResults",
    ]
    resources = [aws_cloudwatch_log_group.device_telemetry.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/kubernetes-service-account"
      values   = ["api", "mcp"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:StopQuery"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/kubernetes-service-account"
      values   = ["api", "mcp"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream"]
    resources = ["${aws_cloudwatch_log_group.device_telemetry.arn}:log-stream:*"]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/kubernetes-service-account"
      values   = ["api"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/kubernetes-service-account"
      values   = ["api", "worker", "mcp"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/kubernetes-service-account"
      values   = ["worker"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.device_telemetry_writer.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/kubernetes-service-account"
      values   = ["api"]
    }
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

# ----- Device telemetry writer role -----

data "aws_iam_policy_document" "device_telemetry_writer_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.cp_runtime.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/kubernetes-service-account"
      values   = ["api"]
    }
  }
}

resource "aws_iam_role" "device_telemetry_writer" {
  name               = "${var.name_prefix}-device-telemetry-writer"
  description        = "Short-lived device access to publish logs and metrics for ${var.name_prefix}."
  assume_role_policy = data.aws_iam_policy_document.device_telemetry_writer_assume.json

  tags = local.tags
}

data "aws_iam_policy_document" "device_telemetry_writer" {
  statement {
    effect    = "Allow"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.device_telemetry.arn}:log-stream:*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "device_telemetry_writer" {
  name   = "${var.name_prefix}-device-telemetry-writer"
  role   = aws_iam_role.device_telemetry_writer.id
  policy = data.aws_iam_policy_document.device_telemetry_writer.json
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
