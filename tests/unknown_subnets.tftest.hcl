mock_provider "aws" {
  source = "./tests/mocks"
}

run "accepts_subnet_ids_known_only_at_apply" {
  command = plan

  module {
    source = "./tests/fixtures/unknown_subnets"
  }
}
