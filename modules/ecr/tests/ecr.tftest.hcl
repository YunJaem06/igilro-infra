mock_provider "aws" {}

variables {
  repository_name = "igilro-test/server"
}

run "protect_release_images" {
  command = plan

  assert {
    condition = (
      aws_ecr_repository.this.image_tag_mutability == "IMMUTABLE" &&
      !aws_ecr_repository.this.force_delete &&
      aws_ecr_repository.this.encryption_configuration[0].encryption_type == "AES256" &&
      aws_ecr_repository.this.image_scanning_configuration[0].scan_on_push
    )
    error_message = "Release tags must be immutable, encrypted and scanned, and image deletion must remain explicit."
  }

  assert {
    condition = (
      length(jsondecode(aws_ecr_lifecycle_policy.this.policy).rules) == 1 &&
      jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[0].selection.tagStatus == "untagged" &&
      jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[0].selection.countNumber == 14
    )
    error_message = "Automatic cleanup must retain all tagged rollback images."
  }
}
