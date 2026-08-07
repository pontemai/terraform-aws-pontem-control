# A complete root module. Copy this directory, change the values marked below,
# and it is the whole infrastructure half of the install.

provider "aws" {
  region = "us-east-1"
}

module "pontem_control" {
  source = "../../"

  # ----- Required: change all of these -----

  # The control-plane hostname. The Route53 options below can manage its DNS.
  app_domain_name = "pontem.example.com"

  # IAM principals allowed to use kubectl. Include the installer and use its role
  # or user ARN, not the arn:aws:sts::...:assumed-role/... session ARN.
  cluster_admin_principal_arns = [
    "arn:aws:iam::123456789012:role/YourAdminRole",
  ]

  # Where those principals connect from. Sources outside this list cannot reach the
  # Kubernetes API; ["0.0.0.0/0"] allows all of them.
  cluster_endpoint_public_access_cidrs = [
    "203.0.113.0/24",
  ]

  # Your identity provider. The API validates bearer tokens against the issuer and
  # audience; the admin UI signs users in from the browser and needs all three,
  # including the public SPA client id. None of them is secret.
  oidc_issuer    = "https://your-tenant.us.auth0.com/"
  oidc_audience  = "https://pontem.example.com"
  oidc_client_id = "YourAuth0SpaClientId"

  # ----- Optional -----

  # Set this after Pontem sends it, then re-apply and regenerate values.yaml.
  # The placeholder lets Helm install, but managed package pulls fail.
  # wif_audience = "//iam.googleapis.com/projects/…/providers/aws-eks"

  # Use an existing hosted zone for certificate validation and application DNS.
  # route53_zone_id = "Z0123456789ABCDEFGHIJ"

  # Or create one; follow the README's two-step apply before installing Helm.
  # create_route53_zone = true

  # The two inputs that move most of the monthly bill; each trades away an AZ's
  # worth of independence.
  # single_nat_gateway = true
  # db_multi_az        = false

  tags = {
    Environment = "production"
    Owner       = "platform-team"
  }
}
