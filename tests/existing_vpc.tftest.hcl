mock_provider "aws" {
  source = "./tests/mocks"

  mock_data "aws_vpc" {
    defaults = {
      id                   = "vpc-0123456789abcdef0"
      enable_dns_support   = true
      enable_dns_hostnames = true
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      vpc_id            = "vpc-0123456789abcdef0"
      availability_zone = "us-east-1a"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/example"
    }
  }

  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:example"
    }
  }
}

variables {
  app_domain_name                      = "pontem.example.com"
  cluster_admin_principal_arns         = ["arn:aws:iam::123456789012:role/installer"]
  cluster_endpoint_public_access_cidrs = ["203.0.113.0/24"]
  oidc_issuer                          = "https://example.us.auth0.com/"
  oidc_audience                        = "https://api.example.com"
  oidc_client_id                       = "ExampleSpaClientId"
  vpc_id                               = "vpc-0123456789abcdef0"
  private_subnet_ids                   = ["subnet-00000000000000001", "subnet-00000000000000002"]
  public_subnet_ids                    = ["subnet-00000000000000003", "subnet-00000000000000004"]
}

override_data {
  target = data.aws_subnet.private[1]
  values = {
    vpc_id            = "vpc-0123456789abcdef0"
    availability_zone = "us-east-1b"
  }
}

override_data {
  target = data.aws_subnet.public[1]
  values = {
    vpc_id            = "vpc-0123456789abcdef0"
    availability_zone = "us-east-1b"
  }
}

run "supplied_vpc_leaves_network_ownership_with_customer" {
  command = plan

  assert {
    condition = alltrue([
      length(aws_vpc.this) == 0,
      length(aws_default_security_group.this) == 0,
      length(aws_internet_gateway.this) == 0,
      length(aws_subnet.private) == 0,
      length(aws_subnet.public) == 0,
      length(aws_eip.nat) == 0,
      length(aws_nat_gateway.this) == 0,
      length(aws_route_table.private) == 0,
      length(aws_route_table.public) == 0,
      length(aws_route_table_association.private) == 0,
      length(aws_route_table_association.public) == 0,
      length(aws_flow_log.vpc) == 0,
      length(aws_cloudwatch_log_group.vpc_flow) == 0,
      length(aws_iam_role.vpc_flow) == 0,
      length(aws_iam_role_policy.vpc_flow) == 0,
    ])
    error_message = "Supplied-VPC mode must not manage networking or any flow-log resources, even with flow logs enabled by default."
  }
}

run "supplied_vpc_wires_workloads_and_public_alb" {
  command = apply

  assert {
    condition = (
      output.vpc_id == var.vpc_id &&
      output.private_subnet_ids == var.private_subnet_ids &&
      aws_eks_cluster.this.vpc_config[0].subnet_ids == toset(var.private_subnet_ids) &&
      aws_db_subnet_group.this.subnet_ids == toset(var.private_subnet_ids) &&
      aws_security_group.db.vpc_id == var.vpc_id &&
      one(aws_security_group.db.ingress).security_groups == toset([aws_eks_cluster.this.vpc_config[0].cluster_security_group_id])
    )
    error_message = "EKS and RDS must use the supplied network while retaining the database's cluster-SG-only ingress."
  }

  assert {
    condition = (
      yamldecode(output.helm_values).awsTurnkey.scheme == "internet-facing" &&
      tolist(yamldecode(output.helm_values).awsTurnkey.subnetIds) == var.public_subnet_ids &&
      !contains(keys(yamldecode(output.helm_values).ingress.annotations), "alb.ingress.kubernetes.io/subnets")
    )
    error_message = "Supplied public subnets must reach awsTurnkey.subnetIds, with no annotation fallback."
  }
}

run "supplied_vpc_internal_alb_uses_private_subnets" {
  command = apply

  variables {
    alb_scheme        = "internal"
    public_subnet_ids = []
  }

  assert {
    condition = (
      yamldecode(output.helm_values).awsTurnkey.scheme == "internal" &&
      tolist(yamldecode(output.helm_values).awsTurnkey.subnetIds) == var.private_subnet_ids
    )
    error_message = "An internal ALB must select the supplied private subnets."
  }
}

run "rejects_private_subnets_without_vpc" {
  command = plan

  variables {
    vpc_id            = null
    public_subnet_ids = []
  }

  expect_failures = [var.private_subnet_ids]
}

run "rejects_public_subnets_without_vpc" {
  command = plan

  variables {
    vpc_id             = null
    private_subnet_ids = []
  }

  expect_failures = [var.public_subnet_ids]
}

run "rejects_missing_private_subnets" {
  command = plan

  variables {
    private_subnet_ids = []
  }

  expect_failures = [var.private_subnet_ids]
}

run "rejects_missing_public_subnets" {
  command = plan

  variables {
    public_subnet_ids = []
  }

  expect_failures = [var.public_subnet_ids]
}

run "rejects_public_subnets_for_internal_alb" {
  command = plan

  variables {
    alb_scheme = "internal"
  }

  expect_failures = [var.public_subnet_ids]
}

run "rejects_duplicate_private_subnets" {
  command = plan

  variables {
    private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000001"]
  }

  expect_failures = [var.private_subnet_ids]
}

run "rejects_duplicate_public_subnets" {
  command = plan

  variables {
    public_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000003"]
  }

  expect_failures = [var.public_subnet_ids]
}

run "rejects_overlapping_subnets" {
  command = plan

  variables {
    public_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000004"]
  }

  expect_failures = [var.public_subnet_ids]
}

run "rejects_bad_subnet_id" {
  command = plan

  variables {
    private_subnet_ids = [null, "subnet-00000000000000002"]
  }

  expect_failures = [var.private_subnet_ids]
}

run "rejects_empty_vpc_id" {
  command = plan

  variables {
    vpc_id = ""
  }

  expect_failures = [var.vpc_id]
}

run "rejects_invalid_alb_scheme" {
  command = plan

  variables {
    alb_scheme        = "public"
    public_subnet_ids = []
  }

  expect_failures = [var.alb_scheme]
}

run "rejects_subnet_in_another_vpc" {
  command = plan

  override_data {
    target = data.aws_subnet.private[0]
    values = {
      vpc_id            = "vpc-00000000000000000"
      availability_zone = "us-east-1a"
    }
  }

  expect_failures = [data.aws_vpc.existing]
}

run "rejects_public_subnet_in_another_vpc" {
  command = plan

  override_data {
    target = data.aws_subnet.public[0]
    values = {
      vpc_id            = "vpc-00000000000000000"
      availability_zone = "us-east-1a"
    }
  }

  expect_failures = [data.aws_vpc.existing]
}

run "rejects_private_subnets_in_one_az" {
  command = plan

  override_data {
    target = data.aws_subnet.private[1]
    values = {
      vpc_id            = "vpc-0123456789abcdef0"
      availability_zone = "us-east-1a"
    }
  }

  expect_failures = [data.aws_vpc.existing]
}

run "rejects_public_subnets_in_one_az" {
  command = plan

  override_data {
    target = data.aws_subnet.public[1]
    values = {
      vpc_id            = "vpc-0123456789abcdef0"
      availability_zone = "us-east-1a"
    }
  }

  expect_failures = [data.aws_vpc.existing]
}

run "rejects_local_zone" {
  command = plan

  override_data {
    target = data.aws_subnet.private[0]
    values = {
      vpc_id            = "vpc-0123456789abcdef0"
      availability_zone = "us-east-1-atl-1a"
    }
  }

  expect_failures = [data.aws_vpc.existing]
}

run "rejects_disabled_dns_support" {
  command = plan

  override_data {
    target = data.aws_vpc.existing[0]
    values = {
      id                   = "vpc-0123456789abcdef0"
      enable_dns_support   = false
      enable_dns_hostnames = true
    }
  }

  expect_failures = [data.aws_vpc.existing]
}

run "rejects_disabled_dns_hostnames" {
  command = plan

  override_data {
    target = data.aws_vpc.existing[0]
    values = {
      id                   = "vpc-0123456789abcdef0"
      enable_dns_support   = true
      enable_dns_hostnames = false
    }
  }

  expect_failures = [data.aws_vpc.existing]
}

run "accepts_extra_private_subnet_in_same_az_for_public_alb" {
  command = plan

  variables {
    private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000005"]
  }
}

run "rejects_extra_private_subnet_in_same_az_for_internal_alb" {
  command = plan

  variables {
    alb_scheme         = "internal"
    private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000005"]
    public_subnet_ids  = []
  }

  expect_failures = [data.aws_vpc.existing]
}

run "rejects_extra_public_subnet_in_same_az" {
  command = plan

  variables {
    public_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004", "subnet-00000000000000005"]
  }

  expect_failures = [data.aws_vpc.existing]
}

run "managed_vpc_preserves_discovery" {
  command = apply

  variables {
    vpc_id             = null
    private_subnet_ids = []
    public_subnet_ids  = []
  }

  assert {
    condition = (
      yamldecode(output.helm_values).awsTurnkey.scheme == "internet-facing" &&
      !contains(keys(yamldecode(output.helm_values).awsTurnkey), "subnetIds") &&
      output.vpc_id == aws_vpc.this[0].id &&
      toset(output.private_subnet_ids) == aws_eks_cluster.this.vpc_config[0].subnet_ids &&
      toset(output.private_subnet_ids) == aws_db_subnet_group.this.subnet_ids &&
      aws_security_group.db.vpc_id == aws_vpc.this[0].id
    )
    error_message = "Managed mode must retain discovery and use its own VPC/subnets for workloads."
  }
}

run "managed_vpc_internal_alb_preserves_private_discovery" {
  command = apply

  variables {
    vpc_id             = null
    private_subnet_ids = []
    public_subnet_ids  = []
    alb_scheme         = "internal"
  }

  assert {
    condition = (
      yamldecode(output.helm_values).awsTurnkey.scheme == "internal" &&
      !contains(keys(yamldecode(output.helm_values).awsTurnkey), "subnetIds") &&
      alltrue([for subnet in aws_subnet.private : subnet.tags["kubernetes.io/role/internal-elb"] == "1"])
    )
    error_message = "Managed internal ALBs must retain private-subnet discovery."
  }
}
