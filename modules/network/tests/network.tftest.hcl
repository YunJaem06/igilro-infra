mock_provider "aws" {}

variables {
  name_prefix        = "igilro-test"
  aws_region         = "ap-northeast-2"
  vpc_cidr           = "10.42.0.0/16"
  availability_zones = ["ap-northeast-2a", "ap-northeast-2c"]
}

run "private_tiers_and_access_boundaries" {
  command = apply

  assert {
    condition = (
      length(aws_subnet.public) == 2 &&
      length(aws_subnet.application) == 2 &&
      length(aws_subnet.database) == 2 &&
      alltrue([for subnet in aws_subnet.application : !subnet.map_public_ip_on_launch]) &&
      alltrue([for subnet in aws_subnet.database : !subnet.map_public_ip_on_launch]) &&
      length(distinct(concat(
        [for subnet in aws_subnet.public : subnet.cidr_block],
        [for subnet in aws_subnet.application : subnet.cidr_block],
        [for subnet in aws_subnet.database : subnet.cidr_block]
      ))) == 6
    )
    error_message = "Each AZ must have distinct public, private application and isolated DB subnets."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.database_application.referenced_security_group_id == aws_security_group.application.id &&
      aws_vpc_security_group_ingress_rule.database_application.cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.database_application.from_port == 5432 &&
      aws_vpc_security_group_ingress_rule.application_alb.referenced_security_group_id == aws_security_group.alb.id &&
      aws_vpc_security_group_ingress_rule.application_alb.cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.application_alb.from_port == 8080
    )
    error_message = "DB and application ingress must use the immediately preceding security group, with no public CIDR."
  }

  assert {
    condition = (
      length(aws_nat_gateway.this) == 1 &&
      alltrue([for route in aws_route.application_internet : route.nat_gateway_id == aws_nat_gateway.this["ap-northeast-2a"].id]) &&
      alltrue([for table in aws_route_table.database : length(table.route) == 0]) &&
      aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" &&
      toset(aws_vpc_endpoint.s3.route_table_ids) == toset([for table in aws_route_table.application : table.id])
    )
    error_message = "Private application traffic must have NAT/S3 egress; DB route tables must have no outbound routes."
  }
}

run "per_az_nat_keeps_egress_in_the_same_az" {
  command = apply

  variables {
    nat_gateway_mode = "per_az"
  }

  assert {
    condition = (
      length(aws_nat_gateway.this) == 2 &&
      alltrue([for az, route in aws_route.application_internet : route.nat_gateway_id == aws_nat_gateway.this[az].id])
    )
    error_message = "per_az must route each private application subnet through its own AZ's NAT gateway."
  }
}

run "reject_duplicate_azs" {
  command = plan

  variables {
    availability_zones = ["ap-northeast-2a", "ap-northeast-2a"]
  }

  expect_failures = [var.availability_zones]
}

run "reject_undersized_vpc" {
  command = plan

  variables {
    vpc_cidr = "10.42.0.0/24"
  }

  expect_failures = [var.vpc_cidr]
}
