mock_provider "aws" {}

variables {
  aws_account_id = "123456789012"
}

run "state_storage_protection" {
  command = apply

  assert {
    condition = (
      aws_s3_bucket.state.bucket == "igilro-tfstate-123456789012-ap-northeast-2" &&
      !aws_s3_bucket.state.force_destroy &&
      aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled" &&
      one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    )
    error_message = "Terraform state must use a versioned, encrypted bucket without forced deletion."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.state.block_public_acls &&
      aws_s3_bucket_public_access_block.state.block_public_policy &&
      aws_s3_bucket_public_access_block.state.ignore_public_acls &&
      aws_s3_bucket_public_access_block.state.restrict_public_buckets &&
      jsondecode(aws_s3_bucket_policy.state.policy).Statement[0].Effect == "Deny" &&
      jsondecode(aws_s3_bucket_policy.state.policy).Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    )
    error_message = "State access must block public exposure and deny non-TLS requests."
  }
}

run "reject_invalid_account_id" {
  command = plan

  variables {
    aws_account_id = "not-an-account"
  }

  expect_failures = [var.aws_account_id]
}
