terraform {
  required_version = ">= 1.11.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.45.0, < 7.0.0"
    }
  }
}

# Resource outputs stay unknown in a plan, just like newly created subnets.
resource "terraform_data" "private_subnet" {
  count = 2
  input = "subnet-0000000000000000${count.index + 1}"
}

module "control" {
  source = "../../.."

  app_domain_name                      = "pontem.example.com"
  cluster_admin_principal_arns         = ["arn:aws:iam::123456789012:role/installer"]
  cluster_endpoint_public_access_cidrs = ["203.0.113.0/24"]
  oidc_issuer                          = "https://example.us.auth0.com/"
  oidc_audience                        = "https://api.example.com"
  oidc_client_id                       = "ExampleSpaClientId"
  vpc_id                               = "vpc-0123456789abcdef0"
  private_subnet_ids                   = terraform_data.private_subnet[*].output
  alb_scheme                           = "internal"
}
