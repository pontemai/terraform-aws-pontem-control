# Inputs `make goldens` renders the golden files from.
#
# These MUST match the `variables` block in render.tftest.hcl. They are not
# shared, because a test file that needed an extra flag to run would be a trap —
# but drift is self-correcting rather than silent: the tests assert the rendered
# output against the golden files byte for byte, so a mismatch here makes
# `terraform test` fail rather than quietly comparing against a different
# rendering.

app_domain_name     = "pontem.example.com"
aws_region          = "us-east-1"
acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-2222-3333-4444-555555555555"
namespace           = "pontem-control"

db_host = "pontem-control.abcdefghijkl.us-east-1.rds.amazonaws.com"
db_port = 5432
db_name = "pontem"
db_user = "app"

oidc_issuer   = "https://example.us.auth0.com/"
oidc_audience = "https://api.example.com"
