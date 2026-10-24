mock_provider "aws" {}

variables {
  name_prefix              = "igilro-test"
  aws_region               = "ap-northeast-2"
  aws_account_id           = "123456789012"
  repository_arns          = ["arn:aws:ecr:ap-northeast-2:123456789012:repository/igilro-test/server"]
  cluster_arn              = "arn:aws:ecs:ap-northeast-2:123456789012:cluster/igilro-test"
  service_arn              = "arn:aws:ecs:ap-northeast-2:123456789012:service/igilro-test/server"
  deployment_parameter_arn = "arn:aws:ssm:ap-northeast-2:123456789012:parameter/igilro-test/deployment"
  task_family_arns = {
    application = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/igilro-test-server:*"
    migration   = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/igilro-test-migration:*"
    bootstrap   = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/igilro-test-bootstrap:*"
  }
  execution_role_arns = { application = "app-exec", migration = "migration-exec", bootstrap = "bootstrap-exec" }
  task_role_arns      = { application = "app-task", migration = "migration-task", bootstrap = "bootstrap-task" }
}

run "oidc_and_task_privileges_are_separate" {
  command = apply
  assert {
    condition = (
      jsondecode(aws_iam_role.github["deploy"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:YunJaem06/igilro-server:environment:dev" &&
      jsondecode(aws_iam_role.github["bootstrap"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:YunJaem06/igilro-server:environment:dev-bootstrap" &&
      jsondecode(aws_iam_role.github["deploy"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    )
    error_message = "OIDC must restrict exact repository/environment and STS audience."
  }
  assert {
    condition = (
      !contains(jsondecode(aws_iam_role_policy.tasks["deploy"].policy).Statement[3].Resource, "bootstrap-task") &&
      jsondecode(aws_iam_role_policy.tasks["deploy"].policy).Statement[4].Resource == [var.task_family_arns.migration] &&
      jsondecode(aws_iam_role_policy.tasks["bootstrap"].policy).Statement[4].Resource == [var.task_family_arns.bootstrap] &&
      jsondecode(aws_iam_role_policy.tasks["deploy"].policy).Statement[3].Condition.StringEquals["iam:PassedToService"] == "ecs-tasks.amazonaws.com" &&
      !strcontains(aws_iam_role_policy.tasks["deploy"].policy, "secretsmanager:") &&
      jsondecode(aws_iam_role_policy.deploy.policy).Statement[2].Resource == var.service_arn
    )
    error_message = "Normal deploy may run migration and update one service, cannot pass bootstrap role or read raw secrets."
  }
}

run "reuse_existing_account_provider" {
  command = apply
  variables { existing_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "Existing account-wide provider must be reused rather than duplicated."
  }
}

run "reject_wildcard_repository" {
  command = plan
  variables { repository = "YunJaem06/*" }
  expect_failures = [var.repository]
}
