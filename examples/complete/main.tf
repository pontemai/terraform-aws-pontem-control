# A complete root module. Copy this directory, change the values marked below,
# and it is the whole infrastructure half of the install.

provider "aws" {
  region = "us-east-1"

  # The module reads the region and account from this provider rather than taking
  # them as inputs, so this block is the single place either is decided.
}

module "pontem_control" {
  source = "../../"

  # ----- Change these four -----

  # The hostname the control plane will be served at. You will point this at the
  # load balancer's address once the chart is installed.
  app_domain_name = "pontem.example.com"

  # Who may reach the Kubernetes API. This is the only path to it — a principal
  # absent from this list cannot run kubectl no matter what IAM it holds, so the
  # identity you will run the install steps as must be here. Use the role or user
  # ARN, not the arn:aws:sts::...:assumed-role/... form that
  # `aws sts get-caller-identity` prints.
  cluster_admin_principal_arns = [
    "arn:aws:iam::123456789012:role/YourAdminRole",
  ]

  # Where those principals connect from. Narrow this to your office or VPN egress
  # if you can; ["0.0.0.0/0"] is a deliberate choice, not a default.
  cluster_endpoint_public_access_cidrs = [
    "203.0.113.0/24",
  ]

  # Your identity provider, for the people who will log in to the admin UI.
  # Neither value is secret. Omit both to deliver them through the application
  # Secret instead.
  oidc_issuer   = "https://your-tenant.us.auth0.com/"
  oidc_audience = "https://pontem.example.com"

  # ----- Optional -----

  # Set this to your hosted zone and the module creates the certificate
  # validation records and waits for the certificate to be issued, so a
  # successful apply means TLS is working. Leave it out and the records are
  # emitted for you to create wherever your DNS lives.
  # route53_zone_id = "Z0123456789ABCDEFGHIJ"

  # Evaluation-scale cost dials. Together these are most of the monthly bill:
  # single_nat_gateway saves roughly $33/month per AZ dropped, and db_multi_az
  # roughly halves the database cost. Both trade away availability, so they are
  # the knobs to turn for a trial and turn back for production.
  # single_nat_gateway = true
  # db_multi_az        = false

  tags = {
    Environment = "production"
    Owner       = "platform-team"
  }
}
