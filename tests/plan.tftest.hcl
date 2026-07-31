# Structural assertions on a full, credential-free plan of the module.
#
# Two things are being guarded. First, the arithmetic: subnet CIDRs, NAT counts,
# and per-AZ route tables are computed from variables, and an off-by-one there
# produces overlapping subnets or an AZ with no egress. Second, the defaults that
# decide whether losing an availability zone or running a destroy is survivable —
# Multi-AZ, deletion protection, backups, secret recovery, and the API endpoint
# allowlist. Each assertion names what breaks if the default moves.

mock_provider "aws" {
  source = "./tests/mocks"
}

mock_provider "random" {}

variables {
  app_domain_name                      = "pontem.example.com"
  cluster_admin_principal_arns         = ["arn:aws:iam::123456789012:role/installer"]
  cluster_endpoint_public_access_cidrs = ["203.0.113.0/24"]
  oidc_issuer                          = "https://example.us.auth0.com/"
  oidc_audience                        = "https://api.example.com"
  oidc_client_id                       = "ExampleSpaClientId"
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
    condition     = aws_db_instance.this.skip_final_snapshot == false
    error_message = "A final snapshot must be taken on delete."
  }

  assert {
    condition     = aws_db_instance.this.backup_retention_period == 14
    error_message = "Automated backups must be on by default; retention is also the point-in-time-recovery window, the only thing that recovers from a bad migration."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted == true
    error_message = "Database storage must be encrypted at rest."
  }

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "The database must never get a public address."
  }

  assert {
    condition     = aws_db_instance.this.engine_lifecycle_support == "open-source-rds-extended-support-disabled"
    error_message = "Extended support must stay disabled — it can only be set at create time, so a missed default here cannot be fixed later without replacing the instance."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "The default must be one NAT gateway per AZ; sharing one makes every AZ's egress depend on a single AZ staying up."
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
    error_message = "Authorization must be access entries only — no aws-auth ConfigMap."
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

  # Non-overlapping /20s, public from the bottom of the VPC block and private from
  # the top, so adding an AZ appends rather than renumbering existing subnets.
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

  # Load-bearing tags: Auto Mode's built-in load balancer controller discovers
  # subnets by them, and without them an Ingress never gets an address.
  assert {
    condition     = aws_subnet.public[0].tags["kubernetes.io/role/elb"] == "1"
    error_message = "Public subnets must carry kubernetes.io/role/elb=1 for ALB subnet discovery."
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

  # ----- Secrets: exactly two, and named off name_prefix -----

  assert {
    condition     = aws_secretsmanager_secret.db_password.name == "pontem-control-db-password" && aws_secretsmanager_secret.device_jwt_signing_key.name == "pontem-control-device-jwt-signing-key"
    error_message = "Secret names must derive from name_prefix so two stacks in one account do not collide."
  }

  assert {
    condition     = random_id.device_jwt_signing_key.byte_length == 32
    error_message = "The device JWT signing key must be exactly 32 bytes; the application's Ed25519 provider rejects anything else at startup."
  }

  assert {
    condition     = random_password.db.special == false
    error_message = "The database password must avoid special characters: it is pasted into a shell command in the README, where a metacharacter silently produces the wrong secret."
  }

  # ----- ACM: no waiter without a hosted zone -----

  assert {
    condition     = length(aws_route53_record.acm_validation) == 0 && length(aws_acm_certificate_validation.app) == 0
    error_message = "With route53_zone_id unset the module must create no DNS records and add no validation waiter — a waiter would block this apply and every later one on a manual DNS step."
  }

  assert {
    condition     = aws_acm_certificate.app.domain_name == "pontem.example.com"
    error_message = "The certificate must cover exactly app_domain_name, which is also the chart's ingress.domain."
  }

  # ----- Log retention -----

  assert {
    condition     = aws_cloudwatch_log_group.cluster.retention_in_days == 90
    error_message = "The control-plane log group must be created here with finite retention; left to EKS it is created with never-expire retention and billed forever."
  }
}

run "issuer_host_reaches_the_admin_app_lowercased" {
  command = plan

  variables {
    oidc_issuer = "https://Example.US.auth0.com/"
  }

  # Hostnames are case-insensitive so a mixed-case issuer is legitimate, but the
  # admin app compares the host it is given against what the provider returns, and
  # the scheme and trailing slash must be gone because the container adds them back.
  assert {
    condition     = local.oidc_domain == "example.us.auth0.com"
    error_message = "The issuer host handed to the admin app must be lowercased with the scheme and any trailing slash removed."
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

  # The regression this guards: collapsing the NAT count without re-pointing the
  # route tables leaves the second AZ's table indexing past the end of the gateway
  # list, or silently drops its default route.
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

  # A third AZ must extend the ranges, not renumber the first two — renumbering an
  # existing subnet replaces it, and replacing a subnet replaces what runs in it.
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

run "external_secrets_iam_is_optional" {
  command = plan

  variables {
    enable_external_secrets_iam = false
  }

  assert {
    condition     = length(aws_iam_role.eso) == 0 && length(aws_iam_role_policy.eso) == 0 && length(aws_eks_pod_identity_association.eso) == 0
    error_message = "Disabling enable_external_secrets_iam must remove the role, its policy, and the association together — a role left without its association is a puzzle for whoever audits it."
  }
}

run "route53_zone_creates_records_and_waits" {
  command = plan

  variables {
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  # With a hosted zone the module owns validation end to end, so a successful
  # apply means TLS actually works rather than merely that a certificate exists.
  assert {
    condition     = length(aws_acm_certificate_validation.app) == 1
    error_message = "Setting route53_zone_id must add the validation waiter so the apply blocks until the certificate is ISSUED."
  }
}

run "name_prefix_flows_into_every_resource_name" {
  command = plan

  variables {
    name_prefix = "acme-pontem"
  }

  # name_prefix is the resources' identity: this is what makes the "changing it
  # replaces the cluster and the database" warning in its description true.
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
