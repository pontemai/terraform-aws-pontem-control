# Mock values for the four data sources this module reads, shared by every test
# file. Only these four need fixed values; everything else the mocked provider
# generates is fine, because nothing asserts on it.
#
# The point of mocking is not to simulate AWS. It is that a mocked provider lets
# `terraform plan` complete with no credentials, which turns the whole resource
# graph — every count, for_each, computed name, and cross-resource reference —
# into something CI can check on a pull request. `terraform validate` alone does
# not evaluate any of that.

# Both attributes: the module reads `region`, and a mock that only set `name`
# would leave `region` a provider-generated string, so anything built from it
# (the kubeconfig command, the tenant-secret ARNs) would be asserted against
# nonsense.
mock_data "aws_region" {
  defaults = {
    name   = "us-east-1"
    region = "us-east-1"
  }
}

mock_data "aws_caller_identity" {
  defaults = {
    account_id = "123456789012"
  }
}

# Four names so a test can raise availability_zone_count and still have zones to
# slice. Deliberately plain AZ names: the real data source filters Local Zones
# out, and a mock that returned one would assert the opposite of the intent.
mock_data "aws_availability_zones" {
  defaults = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  }
}

# The IAM policy documents are built by the provider, so under a mock they render
# as this placeholder rather than real JSON. That means no test here can assert on
# policy CONTENT — the trade for being able to plan at all. Policy content is
# checked by reading it, and by the live apply rehearsal.
mock_data "aws_iam_policy_document" {
  defaults = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}
