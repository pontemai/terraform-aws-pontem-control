# The AWS identities the in-cluster workloads assume, via EKS Pod Identity. The
# Pod Identity agent is built into Auto Mode, so there is no add-on resource
# here — an association is enough.

# ----------------------------------------------------------------------------
# CROSS-REPO CONTRACT with the pontem-control Helm chart
#
# The associations below bind AWS roles to specific ServiceAccounts in a
# specific namespace. They are matched by NAME, server-side, at pod start. If
# these names drift from what the chart actually creates, nothing fails at
# apply time and nothing fails at install time — the pods start, get no AWS
# credentials, and then tenant-secret operations return 500 with AccessDenied
# in the logs. In an account we cannot see, that is close to undebuggable from
# our side, so the names are worth stating explicitly.
#
# Verified against helm/pontem-control in pontemai/pontem-mvp:
#   * namespace           - values.yaml has no namespace key; the chart installs
#                           into whatever `helm install -n` targets, so this is
#                           var.namespace and the README uses the same value.
#   * ServiceAccount names - the bare "api" and "worker", from
#                           values.yaml serviceAccount.{api,worker}.name. NOT
#                           "pontem-control-api": the chart uses the literal
#                           names, and values-aws.yaml does not override them.
#   * "mcp" is intentionally absent from the default: its Deployment and
#                           ServiceAccount are gated on mcp.host, which is empty
#                           unless you turn it on.
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

data "aws_iam_policy_document" "cp_runtime_assume" {
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
  assume_role_policy = data.aws_iam_policy_document.cp_runtime_assume.json

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
# Resource-scoped to the two tenant-secret prefixes (locals.tf), which is what
# keeps this role — the one the application pods hold — unable to read the
# database password or the device signing key.
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

# ----- External Secrets Operator role (optional) -----

# For the ESO path in the README: instead of creating the application's
# Kubernetes Secret by hand from this module's outputs, ESO reads the two boot
# secrets from Secrets Manager and keeps the Kubernetes Secret in sync.

data "aws_iam_policy_document" "eso_assume" {
  count = var.enable_external_secrets_iam ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  count = var.enable_external_secrets_iam ? 1 : 0

  name               = "${var.name_prefix}-external-secrets"
  description        = "External Secrets Operator controller in ${var.name_prefix}, assumed via EKS Pod Identity. Read-only on this module's two boot secrets."
  assume_role_policy = data.aws_iam_policy_document.eso_assume[0].json

  tags = local.tags
}

# Scoped to the two secret ARNs by name rather than a ${name_prefix}-* wildcard.
# With only two secrets there is no policy-churn argument for a wildcard, and
# naming them means a third secret added later has to be granted deliberately.
data "aws_iam_policy_document" "eso" {
  count = var.enable_external_secrets_iam ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      aws_secretsmanager_secret.db_password.arn,
      aws_secretsmanager_secret.device_jwt_signing_key.arn,
    ]
  }
}

resource "aws_iam_role_policy" "eso" {
  count = var.enable_external_secrets_iam ? 1 : 0

  name   = "${var.name_prefix}-external-secrets"
  role   = aws_iam_role.eso[0].id
  policy = data.aws_iam_policy_document.eso[0].json
}

resource "aws_eks_pod_identity_association" "eso" {
  count = var.enable_external_secrets_iam ? 1 : 0

  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.external_secrets_namespace
  service_account = var.external_secrets_service_account
  role_arn        = aws_iam_role.eso[0].arn

  tags = local.tags
}
