# The variable validations, checked by asserting they actually reject bad input.
#
# These are the guardrails someone stamping this module will genuinely trip, and
# a validation with a typo in its condition is worse than no validation — it
# reads as protection while accepting anything.
#
# The provider is mocked, which is what keeps this credential-free. A real
# provider would not do: Terraform evaluates variable validations lazily, as part
# of the same graph walk that reads data sources, so a plan with real credentials
# missing fails on the data sources before it ever reaches the validation being
# tested.
mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  app_domain_name                      = "pontem.example.com"
  cluster_admin_principal_arns         = ["arn:aws:iam::123456789012:role/admin"]
  cluster_endpoint_public_access_cidrs = ["203.0.113.0/24"]
  oidc_issuer                          = "https://example.us.auth0.com/"
  oidc_audience                        = "https://api.example.com"
  oidc_client_id                       = "ExampleSpaClientId"
}

run "rejects_kubernetes_below_1_30" {
  command = plan

  variables {
    kubernetes_version = "1.29"
  }

  # The chart's preStop sleep action does not exist before 1.30. Accepting 1.29
  # would install cleanly and then fail to drain connections on every rollout.
  expect_failures = [var.kubernetes_version]
}

run "rejects_malformed_kubernetes_version" {
  command = plan

  variables {
    kubernetes_version = "1.36.2"
  }

  expect_failures = [var.kubernetes_version]
}

run "rejects_empty_cluster_admins" {
  command = plan

  variables {
    cluster_admin_principal_arns = []
  }

  # With the cluster-creator bootstrap flag off, an empty list produces a cluster
  # nobody can run kubectl against, and the only fix is another apply.
  expect_failures = [var.cluster_admin_principal_arns]
}

run "rejects_assumed_role_form_for_cluster_admins" {
  command = plan

  variables {
    cluster_admin_principal_arns = ["arn:aws:sts::123456789012:assumed-role/admin/session"]
  }

  # EKS access entries reject the sts assumed-role form. Easy mistake to make,
  # because it is exactly the ARN `aws sts get-caller-identity` prints.
  expect_failures = [var.cluster_admin_principal_arns]
}

run "rejects_empty_public_access_cidrs" {
  command = plan

  variables {
    cluster_endpoint_public_access_cidrs = []
  }

  expect_failures = [var.cluster_endpoint_public_access_cidrs]
}

run "rejects_non_cidr_public_access_entry" {
  command = plan

  variables {
    cluster_endpoint_public_access_cidrs = ["203.0.113.4"]
  }

  # A bare address without a prefix length is the most likely way to get this
  # wrong, and AWS's own error for it is not obviously about the missing /32.
  expect_failures = [var.cluster_endpoint_public_access_cidrs]
}

run "rejects_single_availability_zone" {
  command = plan

  variables {
    availability_zone_count = 1
  }

  # Both EKS and the RDS subnet group require two AZs; one AZ fails partway
  # through an apply that has already created a VPC.
  expect_failures = [var.availability_zone_count]
}

run "rejects_uppercase_name_prefix" {
  command = plan

  variables {
    name_prefix = "Pontem-Control"
  }

  expect_failures = [var.name_prefix]
}

run "rejects_consecutive_hyphens_in_name_prefix" {
  command = plan

  variables {
    name_prefix = "acme--pontem"
  }

  # Passes every other naming rule but RDS rejects a doubled hyphen in a database
  # identifier — and it rejects it at instance creation, after the VPC, the NAT
  # gateways, and a fifteen-minute cluster create have already succeeded.
  expect_failures = [var.name_prefix]
}

run "rejects_name_prefix_inside_the_tenant_secret_grant" {
  command = plan

  variables {
    name_prefix = "tenant"
  }

  # Not a naming nit: the pods hold GetSecretValue on secret:tenant-*, so this
  # prefix would place the database password and the device signing key inside a
  # grant the application already has.
  expect_failures = [var.name_prefix]
}

run "rejects_domain_with_scheme" {
  command = plan

  variables {
    app_domain_name = "https://pontem.example.com"
  }

  # A scheme here would go into the ACM certificate's domain name and into the
  # chart's ingress.domain, neither of which accepts a URL.
  expect_failures = [var.app_domain_name]
}

run "rejects_empty_route53_zone_id" {
  command = plan

  variables {
    route53_zone_id = ""
  }

  expect_failures = [var.route53_zone_id]
}

run "rejects_unsupported_secret_recovery_window" {
  command = plan

  variables {
    secret_recovery_window_days = 3
  }

  # Secrets Manager accepts 0 or 7-30 and nothing between; 1-6 is rejected at
  # apply time with a message about the recovery window, not about the value.
  expect_failures = [var.secret_recovery_window_days]
}

run "rejects_vpc_cidr_too_small_for_subnets" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/24"
  }

  # cidrsubnet() would fail deep in the VPC resources with an arithmetic error
  # that says nothing about the CIDR being too small for per-AZ /20s.
  expect_failures = [var.vpc_cidr]
}

run "rejects_backup_retention_over_the_rds_limit" {
  command = plan

  variables {
    db_backup_retention_period = 40
  }

  expect_failures = [var.db_backup_retention_period]
}

run "rejects_issuer_with_a_path" {
  command = plan

  variables {
    oidc_issuer = "https://example.okta.com/oauth2/default"
  }

  # The admin app takes the identity provider's host alone and rebuilds the issuer
  # URL from it, so an issuer carrying a path cannot be represented there. Failing
  # here beats an admin UI that redirects to a login page that does not exist.
  expect_failures = [var.oidc_issuer]
}

run "rejects_issuer_without_a_scheme" {
  command = plan

  variables {
    oidc_issuer = "example.us.auth0.com"
  }

  expect_failures = [var.oidc_issuer]
}

run "rejects_empty_oidc_client_id" {
  command = plan

  variables {
    oidc_client_id = ""
  }

  # The one input whose absence produces a healthy-looking deployment with an
  # unusable admin UI, so it is worth rejecting at plan time.
  expect_failures = [var.oidc_client_id]
}
