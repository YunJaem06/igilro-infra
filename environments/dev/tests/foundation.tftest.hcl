mock_provider "aws" {}

variables {
  aws_account_id = "123456789012"
}

run "development_foundation_wiring" {
  command = apply

  assert {
    condition = (
      output.server_repository_name == "igilro-dev/server" &&
      length(output.public_subnet_ids) == 2 &&
      length(output.application_subnet_ids) == 2 &&
      length(output.database_subnet_ids) == 2 &&
      length(output.nat_gateway_ids) == 1 &&
      length(distinct(values(output.security_group_ids))) == 3
    )
    error_message = "The dev environment must connect isolated network tiers and its own immutable image repository."
  }
}
