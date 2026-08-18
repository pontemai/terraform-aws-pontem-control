# Module tests run against mock providers; each assertion checks public behavior.

mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  app_domain_name                      = "pontem.example.com"
  cluster_admin_principal_arns         = ["arn:aws:iam::123456789012:role/installer"]
  cluster_endpoint_public_access_cidrs = ["203.0.113.0/24"]
  oidc_issuer                          = "https://example.us.auth0.com/"
  oidc_audience                        = "https://api.example.com"
  oidc_client_id                       = "ExampleSpaClientId"
}

override_resource {
  target          = aws_cloudwatch_log_group.device_telemetry
  override_during = plan
  values = {
    arn = "arn:aws:logs:us-east-1:123456789012:log-group:/pontem-control/device"
  }
}

override_resource {
  target          = aws_iam_role.cp_runtime
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/pontem-control-cp-runtime"
  }
}

override_resource {
  target          = aws_iam_role.device_telemetry_writer
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/pontem-control-device-telemetry-writer"
  }
}

run "default_configuration" {
  command = plan

  # ----- Durability and access defaults -----

  assert {
    condition     = aws_db_instance.this.multi_az == true
    error_message = "The database must default to Multi-AZ: it is the only durable store here, and single-AZ turns an AZ event into an outage plus a restore."
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection == true
    error_message = "The database must default to deletion-protected; without it `terraform destroy` removes the only durable store with no confirmation step."
  }

  assert {
    condition     = aws_eks_cluster.this.deletion_protection == true
    error_message = "The EKS cluster must default to deletion-protected; deleting it before its in-cluster load balancers are removed leaves orphaned AWS resources behind."
  }

  assert {
    condition     = aws_db_instance.this.skip_final_snapshot == false
    error_message = "A final snapshot must be taken on delete; without one a destroy leaves nothing to restore from."
  }

  assert {
    condition     = aws_db_instance.this.backup_retention_period == 14
    error_message = "Automated backups must be on by default; retention is also the point-in-time-recovery window, the only thing that recovers from a bad migration."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted == true
    error_message = "Database storage must be encrypted at rest; encryption cannot be turned on after the instance exists."
  }

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "The database must never get a public address; the security group is the only thing standing between it and the internet if it does."
  }

  assert {
    condition     = aws_db_instance.this.engine_lifecycle_support == "open-source-rds-extended-support-disabled"
    error_message = "Extended support must stay disabled — it can only be set at create time, so a missed default here cannot be fixed later without replacing the instance."
  }

  assert {
    condition     = toset(aws_db_instance.this.enabled_cloudwatch_logs_exports) == toset(["postgresql", "upgrade"])
    error_message = "RDS must export its PostgreSQL and upgrade logs so database errors and upgrade failures are available after the instance is gone."
  }

  assert {
    condition     = aws_db_instance.this.password_wo_version == 1
    error_message = "The RDS password must use its write-only argument and an explicit version so Terraform never stores the password and rotates it only when requested."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "The default must be one NAT gateway per AZ; sharing one makes every AZ's egress depend on a single AZ staying up."
  }

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0
    error_message = "The VPC default security group must have no ingress or egress rules so unused resources cannot communicate through its permissive AWS defaults."
  }

  assert {
    condition     = aws_secretsmanager_secret.db_password.recovery_window_in_days == 30
    error_message = "Secrets must default to a non-zero recovery window; at 0 a deleted secret is unrecoverable."
  }

  # ----- Cluster access: the part that locks people out -----

  assert {
    condition     = aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    error_message = "The cluster-creator bootstrap flag must stay off; it collides with the explicit access entry for the same principal (ResourceInUseException)."
  }

  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API"
    error_message = "Authorization must be access entries only; falling back to the aws-auth ConfigMap puts cluster access in a mutable in-cluster object this module does not manage."
  }

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].public_access_cidrs == toset(["203.0.113.0/24"])
    error_message = "The public API endpoint must be restricted to the CIDRs given, not left open to every source."
  }

  assert {
    condition     = length(aws_eks_access_entry.admin) == 1 && length(aws_eks_access_policy_association.admin) == 1
    error_message = "Each principal in cluster_admin_principal_arns needs both an access entry and a cluster-admin policy association; an entry without the association grants nothing."
  }

  # ----- Auto Mode -----

  assert {
    condition     = aws_eks_cluster.this.bootstrap_self_managed_addons == false
    error_message = "Auto Mode rejects CreateCluster with the self-managed add-on bootstrap enabled."
  }

  assert {
    condition     = aws_eks_cluster.this.compute_config[0].enabled && aws_eks_cluster.this.kubernetes_network_config[0].elastic_load_balancing[0].enabled && aws_eks_cluster.this.storage_config[0].block_storage[0].enabled
    error_message = "Auto Mode's compute, load balancing, and block storage blocks toggle together — enabling compute alone is rejected."
  }

  assert {
    condition     = aws_eks_cluster.this.upgrade_policy[0].support_type == "STANDARD"
    error_message = "Support type must be STANDARD; EXTENDED bills the control plane at roughly six times the rate."
  }

  # ----- Subnet arithmetic -----

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.0.0.0/20" && aws_subnet.public[1].cidr_block == "10.0.16.0/20"
    error_message = "Public subnet CIDRs must be consecutive /20s from the bottom of vpc_cidr."
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.0.128.0/20" && aws_subnet.private[1].cidr_block == "10.0.144.0/20"
    error_message = "Private subnet CIDRs must start half-way up vpc_cidr so the public and private ranges never interleave."
  }

  assert {
    condition     = aws_subnet.public[0].availability_zone == "us-east-1a" && aws_subnet.private[0].availability_zone == "us-east-1a"
    error_message = "Each index must put its public and private subnet in the same AZ; otherwise a NAT gateway serves a route table in another zone and pays cross-AZ transfer for all egress."
  }

  assert {
    condition     = aws_subnet.public[0].tags["kubernetes.io/role/elb"] == "1"
    error_message = "Public subnets must carry kubernetes.io/role/elb=1 for ALB subnet discovery."
  }

  assert {
    condition     = alltrue([for subnet in aws_subnet.public : subnet.map_public_ip_on_launch == false])
    error_message = "Public subnets must not assign public IPv4 addresses to every EC2 instance launched in them; the ALB and NAT gateways manage their own addresses."
  }

  assert {
    condition     = aws_subnet.private[0].tags["kubernetes.io/role/internal-elb"] == "1"
    error_message = "Private subnets must carry kubernetes.io/role/internal-elb=1 for internal load balancer discovery."
  }

  assert {
    condition     = length(aws_route_table.private) == 2 && length(aws_route_table_association.private) == 2
    error_message = "There must be one private route table per AZ, each associated with that AZ's subnet."
  }

  # ----- The Pod Identity contract -----

  assert {
    condition     = length(aws_eks_pod_identity_association.cp_runtime) == 2
    error_message = "Both the api and worker service accounts need an association; a missing one presents as AccessDenied on tenant-secret operations, not as a startup failure."
  }

  assert {
    condition     = alltrue([for assoc in aws_eks_pod_identity_association.cp_runtime : assoc.namespace == "pontem-control"])
    error_message = "Associations must bind service accounts in var.namespace — they are matched by name, so a namespace mismatch fails silently at runtime."
  }

  assert {
    condition     = toset([for assoc in aws_eks_pod_identity_association.cp_runtime : assoc.service_account]) == toset(["api", "worker"])
    error_message = "The bound service accounts must be the bare names `api` and `worker`, which is what the chart creates — not `pontem-control-api`."
  }

  assert {
    condition = try(
      aws_eks_pod_identity_association.eso.namespace == "pontem-control" &&
      aws_eks_pod_identity_association.eso.service_account == "external-secrets",
      false,
    )
    error_message = "External Secrets Operator must always be associated with its fixed ServiceAccount in var.namespace."
  }

  assert {
    condition = try(
      jsondecode(aws_iam_role.cp_runtime.assume_role_policy).Statement[0].Condition.StringEquals == {
        "aws:RequestTag/eks-cluster-arn"            = ["arn:aws:eks:us-east-1:123456789012:cluster/pontem-control"]
        "aws:RequestTag/kubernetes-namespace"       = ["pontem-control"]
        "aws:RequestTag/kubernetes-service-account" = ["api", "worker"]
        "aws:SourceAccount"                         = ["123456789012"]
      } &&
      jsondecode(aws_iam_role.eso.assume_role_policy).Statement[0].Condition.StringEquals == {
        "aws:RequestTag/eks-cluster-arn"            = ["arn:aws:eks:us-east-1:123456789012:cluster/pontem-control"]
        "aws:RequestTag/kubernetes-namespace"       = ["pontem-control"]
        "aws:RequestTag/kubernetes-service-account" = ["external-secrets"]
        "aws:SourceAccount"                         = ["123456789012"]
      },
      false,
    )
    error_message = "Each Pod Identity role must trust only its exact cluster, namespace, and service accounts."
  }

  assert {
    condition = try(
      aws_cloudwatch_log_group.device_telemetry.name == "/pontem-control/device" &&
      aws_cloudwatch_log_group.device_telemetry.retention_in_days == 90,
      false,
    )
    error_message = "The device telemetry log group must derive from name_prefix and use the module's finite retention."
  }

  assert {
    condition = try(
      one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:StartQuery")]).effect == "Allow" &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:StartQuery")]).actions) == toset(["logs:StartQuery", "logs:GetQueryResults"]) &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:StartQuery")]).resources) == toset([aws_cloudwatch_log_group.device_telemetry.arn]) &&
      toset(one(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:StartQuery")]).condition).values) == toset(["api", "mcp"]) &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:StopQuery")]).resources) == toset(["*"]) &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:StopQuery")]).actions) == toset(["logs:StopQuery"]) &&
      one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:StopQuery")]).effect == "Allow" &&
      toset(one(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:StopQuery")]).condition).values) == toset(["api", "mcp"]) &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:CreateLogStream")]).resources) == toset(["${aws_cloudwatch_log_group.device_telemetry.arn}:log-stream:*"]) &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:CreateLogStream")]).actions) == toset(["logs:CreateLogStream"]) &&
      one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:CreateLogStream")]).effect == "Allow" &&
      toset(one(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "logs:CreateLogStream")]).condition).values) == toset(["api"]),
      false,
    )
    error_message = "Only api and mcp may read device logs, and only api may create device log streams."
  }

  assert {
    condition = try(
      one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "cloudwatch:GetMetricData")]).effect == "Allow" &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "cloudwatch:GetMetricData")]).resources) == toset(["*"]) &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "cloudwatch:GetMetricData")]).actions) == toset(["cloudwatch:GetMetricData", "cloudwatch:ListMetrics"]) &&
      toset(one(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "cloudwatch:GetMetricData")]).condition).values) == toset(["api", "worker", "mcp"]) &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "cloudwatch:PutMetricData")]).resources) == toset(["*"]) &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "cloudwatch:PutMetricData")]).actions) == toset(["cloudwatch:PutMetricData"]) &&
      one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "cloudwatch:PutMetricData")]).effect == "Allow" &&
      toset(one(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "cloudwatch:PutMetricData")]).condition).values) == toset(["worker"]),
      false,
    )
    error_message = "API, worker, and mcp may read device metrics, but only worker may publish runtime metrics."
  }

  assert {
    condition = try(
      one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "sts:AssumeRole")]).effect == "Allow" &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "sts:AssumeRole")]).actions) == toset(["sts:AssumeRole"]) &&
      toset(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "sts:AssumeRole")]).resources) == toset([aws_iam_role.device_telemetry_writer.arn]) &&
      toset(one(one([for statement in data.aws_iam_policy_document.cp_runtime.statement : statement if contains(statement.actions, "sts:AssumeRole")]).condition).values) == toset(["api"]) &&
      toset(one(one(data.aws_iam_policy_document.device_telemetry_writer_assume.statement).principals).identifiers) == toset([aws_iam_role.cp_runtime.arn]) &&
      one(data.aws_iam_policy_document.device_telemetry_writer_assume.statement).effect == "Allow" &&
      toset(one(data.aws_iam_policy_document.device_telemetry_writer_assume.statement).actions) == toset(["sts:AssumeRole", "sts:TagSession"]) &&
      toset(one(one(data.aws_iam_policy_document.device_telemetry_writer_assume.statement).condition).values) == toset(["api"]),
      false,
    )
    error_message = "Only api sessions of the runtime role may assume the device telemetry writer role."
  }

  assert {
    condition = try(
      length(data.aws_iam_policy_document.device_telemetry_writer.statement) == 2 &&
      one([for statement in data.aws_iam_policy_document.device_telemetry_writer.statement : statement if contains(statement.actions, "logs:PutLogEvents")]).effect == "Allow" &&
      toset(one([for statement in data.aws_iam_policy_document.device_telemetry_writer.statement : statement if contains(statement.actions, "logs:PutLogEvents")]).actions) == toset(["logs:PutLogEvents"]) &&
      toset(one([for statement in data.aws_iam_policy_document.device_telemetry_writer.statement : statement if contains(statement.actions, "logs:PutLogEvents")]).resources) == toset(["${aws_cloudwatch_log_group.device_telemetry.arn}:log-stream:*"]) &&
      one([for statement in data.aws_iam_policy_document.device_telemetry_writer.statement : statement if contains(statement.actions, "cloudwatch:PutMetricData")]).effect == "Allow" &&
      toset(one([for statement in data.aws_iam_policy_document.device_telemetry_writer.statement : statement if contains(statement.actions, "cloudwatch:PutMetricData")]).actions) == toset(["cloudwatch:PutMetricData"]) &&
      toset(one([for statement in data.aws_iam_policy_document.device_telemetry_writer.statement : statement if contains(statement.actions, "cloudwatch:PutMetricData")]).resources) == toset(["*"]),
      false,
    )
    error_message = "Device credentials may write only log events in the device group and CloudWatch metrics."
  }

  assert {
    condition = try(
      length(aws_iam_role.external_dns) == 0 &&
      length(aws_iam_role_policy.external_dns) == 0 &&
      length(aws_eks_pod_identity_association.external_dns) == 0,
      false,
    )
    error_message = "ExternalDNS IAM resources must be absent when neither Route53 input is set."
  }

  # Pin the mock; a generated region would make this string check meaningless.
  assert {
    condition     = aws_secretsmanager_secret.db_password.tags["ManagedBy"] == "terraform" && strcontains(output.update_kubeconfig_command, "--region us-east-1")
    error_message = "The kubeconfig command must name the provider's region."
  }

  assert {
    condition     = !startswith(aws_secretsmanager_secret.db_password.name, "tenant") && !startswith(aws_secretsmanager_secret.db_password.name, "registry-tenant")
    error_message = "The boot secrets must not sit inside the tenant-* prefixes the application pods can read."
  }

  # ----- Secrets: exactly two, and named off name_prefix -----

  assert {
    condition     = aws_secretsmanager_secret.db_password.name == "pontem-control-db-password" && aws_secretsmanager_secret.device_jwt_signing_key.name == "pontem-control-device-jwt-signing-key"
    error_message = "Secret names must derive from name_prefix so two stacks in one account do not collide."
  }

  assert {
    condition = (
      aws_secretsmanager_secret_version.db_password.secret_string_wo_version == 1 &&
      aws_secretsmanager_secret_version.device_jwt_signing_key.secret_string_wo_version == 1
    )
    error_message = "Both boot secrets must use write-only values with explicit versions so neither secret is stored in Terraform state."
  }

  # ----- ACM: no waiter without a hosted zone -----

  assert {
    condition     = length(aws_route53_record.acm_validation) == 0 && length(aws_acm_certificate_validation.app) == 0
    error_message = "Without a Route53 zone the module must create no DNS records or validation waiter; callers manage validation themselves."
  }

  assert {
    condition     = aws_acm_certificate.app.domain_name == "pontem.example.com"
    error_message = "The certificate must cover exactly app_domain_name; a mismatch with the chart's ingress.domain serves the wrong name and browsers reject it."
  }

  # ----- Log retention -----

  assert {
    condition     = aws_cloudwatch_log_group.cluster.retention_in_days == 90
    error_message = "The control-plane log group must be created here with finite retention; left to EKS it is created with never-expire retention and billed forever."
  }

  assert {
    condition = alltrue([
      for name, group in aws_cloudwatch_log_group.rds :
      group.name == "/aws/rds/instance/pontem-control/${name}" && group.retention_in_days == 90
    ]) && toset(keys(aws_cloudwatch_log_group.rds)) == toset(["postgresql", "upgrade"])
    error_message = "The PostgreSQL and upgrade log groups must use RDS's expected names and the module's finite retention."
  }

  assert {
    condition = try(
      length(aws_flow_log.vpc) == 1 &&
      aws_flow_log.vpc[0].traffic_type == "ALL" &&
      aws_cloudwatch_log_group.vpc_flow[0].retention_in_days == 90 &&
      jsondecode(aws_iam_role.vpc_flow[0].assume_role_policy).Statement[0].Condition == {
        ArnLike = {
          "aws:SourceArn" = "arn:aws:ec2:us-east-1:123456789012:vpc-flow-log/*"
        }
        StringEquals = {
          "aws:SourceAccount" = "123456789012"
        }
      },
      false,
    )
    error_message = "VPC Flow Logs must default on for all traffic and use the module's finite CloudWatch retention."
  }
}

run "vpc_flow_logs_can_be_disabled" {
  command = plan

  variables {
    enable_vpc_flow_logs = false
  }

  assert {
    condition = try(
      length(aws_flow_log.vpc) == 0 &&
      length(aws_cloudwatch_log_group.vpc_flow) == 0 &&
      length(aws_iam_role.vpc_flow) == 0 &&
      length(aws_iam_role_policy.vpc_flow) == 0,
      false,
    )
    error_message = "Disabling VPC Flow Logs must remove the flow log, CloudWatch group, and delivery IAM role together."
  }
}

run "single_nat_gateway_still_routes_every_az" {
  command = plan

  variables {
    single_nat_gateway = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_eip.nat) == 1
    error_message = "single_nat_gateway must collapse to exactly one NAT gateway and one EIP."
  }

  assert {
    condition     = length(aws_route_table.private) == 2 && length(aws_route_table_association.private) == 2
    error_message = "Every AZ must keep its own private route table and association even when sharing one NAT gateway."
  }
}

run "three_availability_zones" {
  command = plan

  variables {
    availability_zone_count = 3
  }

  assert {
    condition     = length(aws_subnet.public) == 3 && length(aws_subnet.private) == 3 && length(aws_nat_gateway.this) == 3
    error_message = "availability_zone_count must drive subnets and NAT gateways together."
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.0.0.0/20" && aws_subnet.public[2].cidr_block == "10.0.32.0/20"
    error_message = "Adding an AZ must append a new /20 and leave the existing subnet CIDRs untouched."
  }

  assert {
    condition     = aws_subnet.private[2].cidr_block == "10.0.160.0/20"
    error_message = "Private subnet CIDRs must keep their own contiguous range as AZs are added."
  }

  assert {
    condition     = aws_subnet.private[2].availability_zone == "us-east-1c"
    error_message = "A third private subnet must land in the third AZ, which is what lets the RDS subnet group span three."
  }
}

run "external_secrets_reads_only_the_boot_secrets" {
  command = plan

  override_resource {
    target          = aws_secretsmanager_secret.db_password
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pontem-control-db-password"
    }
  }

  override_resource {
    target          = aws_secretsmanager_secret.device_jwt_signing_key
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pontem-control-device-jwt-signing-key"
    }
  }

  assert {
    condition = try(
      length(jsondecode(aws_iam_role_policy.eso.policy).Statement) == 1 &&
      toset(jsondecode(aws_iam_role_policy.eso.policy).Statement[0].Action) == toset([
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]) &&
      toset(jsondecode(aws_iam_role_policy.eso.policy).Statement[0].Resource) == toset([
        aws_secretsmanager_secret.db_password.arn,
        aws_secretsmanager_secret.device_jwt_signing_key.arn,
      ]),
      false,
    )
    error_message = "The External Secrets Operator policy must grant only read access to the two boot secrets."
  }
}

run "route53_zone_creates_records_and_waits" {
  command = plan

  variables {
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = length(aws_acm_certificate_validation.app) == 1
    error_message = "Setting route53_zone_id must add the validation waiter so the apply blocks until the certificate is ISSUED."
  }

  assert {
    condition = try(
      length(aws_iam_role.external_dns) == 1 &&
      length(aws_iam_role_policy.external_dns) == 1 &&
      length(aws_eks_pod_identity_association.external_dns) == 1 &&
      aws_eks_pod_identity_association.external_dns[0].namespace == "pontem-control" &&
      aws_eks_pod_identity_association.external_dns[0].service_account == "external-dns" &&
      jsondecode(aws_iam_role.external_dns[0].assume_role_policy).Statement[0].Condition.StringEquals == {
        "aws:RequestTag/eks-cluster-arn"            = ["arn:aws:eks:us-east-1:123456789012:cluster/pontem-control"]
        "aws:RequestTag/kubernetes-namespace"       = ["pontem-control"]
        "aws:RequestTag/kubernetes-service-account" = ["external-dns"]
        "aws:SourceAccount"                         = ["123456789012"]
      },
      false,
    )
    error_message = "Setting route53_zone_id must create the ExternalDNS role and restrict it to external-dns in the expected cluster and namespace."
  }

  assert {
    condition = try(
      jsondecode(aws_iam_role_policy.external_dns[0].policy) == {
        Version = "2012-10-17"
        Statement = [
          {
            Effect   = "Allow"
            Action   = ["route53:ChangeResourceRecordSets"]
            Resource = ["arn:aws:route53:::hostedzone/Z0123456789ABCDEFGHIJ"]
            Condition = {
              "ForAllValues:StringEquals" = {
                "route53:ChangeResourceRecordSetsActions" = ["CREATE", "UPSERT", "DELETE"]
                "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [
                  "pontem.example.com",
                  "external-dns-a.pontem.example.com",
                  "external-dns-aaaa.pontem.example.com",
                  "external-dns-cname.pontem.example.com",
                ]
                "route53:ChangeResourceRecordSetsRecordTypes" = ["A", "AAAA", "CNAME", "TXT"]
              }
            }
          },
          {
            Effect   = "Allow"
            Action   = ["route53:ListResourceRecordSets"]
            Resource = ["arn:aws:route53:::hostedzone/Z0123456789ABCDEFGHIJ"]
          },
          {
            Effect   = "Allow"
            Action   = ["route53:ListHostedZones"]
            Resource = ["*"]
          },
        ]
      },
      false,
    )
    error_message = "ExternalDNS may change only A/AAAA/CNAME and ownership TXT records for app_domain_name in the selected hosted zone; read access must be exactly ListHostedZones and ListResourceRecordSets."
  }
}

run "organization_scope_is_added_to_every_pod_identity_role" {
  command = plan

  variables {
    aws_organization_id = "o-abc123def456"
    route53_zone_id     = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition = alltrue([
      for policy in [
        aws_iam_role.cp_runtime.assume_role_policy,
        aws_iam_role.eso.assume_role_policy,
        aws_iam_role.external_dns[0].assume_role_policy,
      ] : jsondecode(policy).Statement[0].Condition.StringEquals["aws:SourceOrgId"] == ["o-abc123def456"]
    ])
    error_message = "Setting aws_organization_id must add the organization boundary to every Pod Identity trust policy."
  }
}

run "create_route53_zone_gets_the_same_automation_as_an_existing_zone" {
  command = plan

  variables {
    create_route53_zone = true
  }

  override_resource {
    target          = aws_route53_zone.this
    override_during = plan
    values = {
      zone_id      = "ZCREATED123456789"
      name_servers = ["ns-1.awsdns.example", "ns-2.awsdns.example"]
    }
  }

  override_resource {
    target          = aws_acm_certificate.app
    override_during = plan
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/example"
      domain_validation_options = [
        {
          domain_name           = "pontem.example.com"
          resource_record_name  = "_acme-challenge.pontem.example.com"
          resource_record_type  = "CNAME"
          resource_record_value = "validation.example.com"
        },
      ]
    }
  }

  override_resource {
    target          = aws_db_instance.this
    override_during = plan
    values = {
      address = "db.example.com"
    }
  }

  assert {
    condition     = length(aws_route53_zone.this) == 1 && aws_route53_zone.this[0].name == "pontem.example.com"
    error_message = "create_route53_zone must create exactly one hosted zone, named for app_domain_name."
  }

  assert {
    condition     = length(aws_route53_record.acm_validation) == 1 && length(aws_acm_certificate_validation.app) == 1
    error_message = "create_route53_zone must validate the certificate the same way an existing route53_zone_id does."
  }

  assert {
    condition = try(
      length(aws_iam_role.external_dns) == 1 &&
      length(aws_iam_role_policy.external_dns) == 1 &&
      length(aws_eks_pod_identity_association.external_dns) == 1 &&
      one([
        for statement in jsondecode(aws_iam_role_policy.external_dns[0].policy).Statement : statement.Resource
        if contains(statement.Action, "route53:ChangeResourceRecordSets")
      ]) == ["arn:aws:route53:::hostedzone/ZCREATED123456789"],
      false,
    )
    error_message = "create_route53_zone must pass the new zone ID to the ExternalDNS IAM policy."
  }

  assert {
    condition     = strcontains(output.helm_values, "zone-id-filter: \"ZCREATED123456789\"")
    error_message = "create_route53_zone must pass the new zone ID to the rendered ExternalDNS values."
  }

  assert {
    condition     = toset(output.route53_name_servers) == toset(["ns-1.awsdns.example", "ns-2.awsdns.example"])
    error_message = "route53_name_servers must return the new zone's delegation servers."
  }
}

run "create_route53_zone_and_route53_zone_id_are_mutually_exclusive" {
  command = plan

  variables {
    create_route53_zone = true
    route53_zone_id     = "Z0123456789ABCDEFGHIJ"
  }

  expect_failures = [var.route53_zone_id]
}

run "name_prefix_flows_into_every_resource_name" {
  command = plan

  variables {
    name_prefix = "acme-pontem"
  }

  assert {
    condition     = aws_eks_cluster.this.name == "acme-pontem" && aws_db_instance.this.identifier == "acme-pontem"
    error_message = "The cluster and database must be named from name_prefix."
  }

  assert {
    condition     = aws_iam_role.cp_runtime.name == "acme-pontem-cp-runtime"
    error_message = "IAM role names must derive from name_prefix so two stacks can share an account."
  }

  assert {
    condition     = aws_cloudwatch_log_group.cluster.name == "/aws/eks/acme-pontem/cluster"
    error_message = "The log group must match the name EKS would auto-create, or EKS creates a second one with never-expire retention."
  }
}
