# The AWS identities the in-cluster workloads assume, via EKS Pod Identity. The
# Pod Identity agent is built into Auto Mode, so there is no add-on resource
# here — an association is enough.

# ----------------------------------------------------------------------------
# CROSS-REPO CONTRACT with the pontem-control Helm chart
#
# The associations below bind AWS roles to ServiceAccounts by NAME, server-side, at
# pod start. If a name drifts from what the chart creates, nothing fails at apply
# time and nothing fails at install time: the pods start, get no AWS credentials,
# and tenant-secret operations return 500 with AccessDenied.
#
# The names are the bare "api" and "worker" from values.yaml
# serviceAccount.{api,worker}.name — NOT "pontem-control-api"; values-aws.yaml does
# not override them. The chart has no namespace key, so it installs wherever
# `helm install -n` points, which must be var.namespace.
# ----------------------------------------------------------------------------

# ----- Control-plane runtime role -----

# AWS allows exactly one Pod Identity role per ServiceAccount, so this single
# role carries every concern that rides the pods' ambient AWS identity:
#
#   1. Tenant-secret CRUD in Secrets Manager. Under secretsBackend.type "aws"
#      the application talks to Secrets Manager directly; the inline policy
#      below is what lets it.
#   2. The AWS identity that Pontem's GCP Workload Identity Federation provider
#      trusts, so the pods can federate into GCP and pull managed agent
#      packages. Nothing extra is configured here — GCP trusts this role by ARN
#      (see the cp_runtime_assumed_role_arn output).

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    effect = "Allow"
    # Pod Identity requires TagSession alongside AssumeRole: the agent tags the
    # session with cluster, namespace, and service-account attributes.
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cp_runtime" {
  name               = "${var.name_prefix}-cp-runtime"
  description        = "Runtime identity for the pontem-control api/worker pods in ${var.name_prefix}, assumed via EKS Pod Identity: tenant-secret CRUD in Secrets Manager, and the AWS identity Pontem's GCP Workload Identity Federation provider trusts."
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = local.tags
}

# These are the Secrets Manager actions the application's secret store actually
# performs, one per method of its storage interface:
#
#   CreateSecret + TagResource      creating a tenant secret (it carries tags)
#   PutSecretValue                  adding a new version
#   GetSecretValue                  reading a version
#   ListSecretVersionIds
#     + UpdateSecretVersionStage    the disable/enable staging-label relabel
#   DescribeSecret                  metadata and version listing
#   DeleteSecret                    force-deleting a tenant's secret
#
# Resource-scoped to the two tenant-secret prefixes (locals.tf).
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

# One association per ServiceAccount. None of them needs to exist yet: the
# association binds by name, and credentials are injected when a pod using that
# ServiceAccount runs. So this applies cleanly before the chart is installed.
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
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

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
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

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
