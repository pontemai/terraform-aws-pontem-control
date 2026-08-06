# A complete root module. Copy this directory, change the values marked below,
# and it is the whole infrastructure half of the install.

provider "aws" {
  region = "us-east-1"

  # The module reads the region and account from this provider rather than taking
  # them as inputs, so this block is the single place either is decided.
}

module "pontem_control" {
  source = "../../"

  # ----- Required: change all of these -----

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

  # Set this once Pontem sends it; see "Register the AWS role with Pontem"
  # in the README.
  # Then re-apply and re-render values.yaml. Left unset, the rendered values carry
  # a placeholder that the chart accepts and the first managed-package pull rejects.
  # wif_audience = "//iam.googleapis.com/projects/…/providers/aws-eks"

  # Set this to your hosted zone and the module creates the certificate
  # validation records and waits for the certificate to be issued, so a
  # successful apply means TLS is working. Leave it out and the records are
  # emitted for you to create wherever your DNS lives.
  # route53_zone_id = "Z0123456789ABCDEFGHIJ"

  # The two inputs that move most of the monthly bill; each trades away an AZ's
  # worth of independence.
  # single_nat_gateway = true
  # db_multi_az        = false

  tags = {
    Environment = "production"
    Owner       = "platform-team"
  }
}
