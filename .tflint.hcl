plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# The AWS ruleset checks resource arguments against the real API — invalid
# instance classes, malformed ARNs, missing required arguments. Worth the
# download for a module nobody can apply in CI.
plugin "aws" {
  enabled = true
  version = "0.42.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
