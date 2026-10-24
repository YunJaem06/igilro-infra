import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock, patch

from botocore.exceptions import ClientError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import deploy_service as deployment


DIGEST = "sha256:" + "a" * 64
REVISION = "b" * 40


def config():
    return {
        "service_created": True, "cluster": "cluster/test", "service": "test-server",
        "api_url": "https://api.example.com", "account_id": "123456789012",
        "repositories": {
            role: {"name": role, "url": "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/" + role}
            for role in ["server", "bootstrap"]},
        "network": {"awsvpcConfiguration": {"assignPublicIp": "DISABLED"}},
        "tasks": {role: {"family": role, "containerDefinitions": [{"name": role}]} for role in ["application", "migration", "bootstrap"]},
    }


def service(definition="old", state="COMPLETED", desired=2):
    return {"status": "ACTIVE", "taskDefinition": definition, "desiredCount": desired,
            "runningCount": desired, "pendingCount": 0,
            "deployments": [{"status": "PRIMARY", "taskDefinition": definition, "rolloutState": state}]}


def ecs_client():
    ecs = MagicMock()
    ecs.describe_services.return_value = {"services": [service()]}
    ecs.register_task_definition.side_effect = lambda **kwargs: {"taskDefinition": {"taskDefinitionArn": kwargs["family"]}}
    ecs.run_task.return_value = {"tasks": [{"taskArn": "task/one"}], "failures": []}
    ecs.describe_tasks.return_value = {"tasks": [{"lastStatus": "STOPPED", "stopCode": "EssentialContainerExited",
                                                "containers": [{"name": "migration", "exitCode": 0}]}]}
    return ecs


class DeploymentTest(unittest.TestCase):
    def test_migration_failure_never_updates_service(self):
        ecs = ecs_client()
        ecs.describe_tasks.return_value["tasks"][0]["containers"][0]["exitCode"] = 1
        with self.assertRaises(deployment.DeploymentError):
            deployment.deploy(ecs, config(), DIGEST)
        ecs.update_service.assert_not_called()
        self.assertEqual(1, ecs.register_task_definition.call_count)

    def test_launch_failure_is_not_a_successful_migration(self):
        ecs = ecs_client()
        ecs.run_task.return_value = {"tasks": [], "failures": [{"reason": "RESOURCE:CPU"}]}
        with self.assertRaises(deployment.DeploymentError):
            deployment.run_once(ecs, config(), "migration", "migration")
        ecs.describe_tasks.assert_not_called()

    def test_timeout_stops_one_off_task(self):
        ecs = ecs_client()
        ecs.describe_tasks.return_value = {"tasks": []}
        with patch.object(deployment.time, "monotonic", side_effect=[0, 0, 100]), patch.object(deployment.time, "sleep"), self.assertRaises(deployment.DeploymentError):
            deployment.run_once(ecs, config(), "migration", "migration", timeout=30)
        ecs.stop_task.assert_called_once()

    def test_missing_container_exit_status_fails_closed(self):
        ecs = ecs_client()
        del ecs.describe_tasks.return_value["tasks"][0]["containers"][0]["exitCode"]
        with self.assertRaises(deployment.DeploymentError):
            deployment.run_once(ecs, config(), "migration", "migration")

    def test_missing_task_then_success_handles_eventual_consistency(self):
        ecs = ecs_client()
        complete = ecs.describe_tasks.return_value
        ecs.describe_tasks.side_effect = [{"tasks": [], "failures": [{"reason": "MISSING"}]}, complete]
        with patch.object(deployment.time, "sleep"):
            deployment.run_once(ecs, config(), "migration", "migration")
        ecs.stop_task.assert_not_called()
        self.assertEqual("DISABLED", ecs.run_task.call_args.kwargs["networkConfiguration"]["awsvpcConfiguration"]["assignPublicIp"])

    def test_one_digest_is_used_for_migration_and_app_and_count_is_preserved(self):
        ecs, settings = ecs_client(), config()
        before = copy.deepcopy(settings)
        with patch.object(deployment, "wait_service"), patch.object(deployment, "check_health"):
            deployment.deploy(ecs, settings, DIGEST)
        tasks = [c.kwargs for c in ecs.register_task_definition.call_args_list]
        self.assertEqual(["migration", "application"], [t["family"] for t in tasks])
        self.assertEqual(tasks[0]["containerDefinitions"][0]["image"], tasks[1]["containerDefinitions"][0]["image"])
        self.assertTrue(tasks[0]["containerDefinitions"][0]["image"].endswith("@" + DIGEST))
        self.assertEqual(2, ecs.update_service.call_args.kwargs["desiredCount"])
        self.assertEqual(before, settings)

    def test_idle_service_is_activated_only_after_migration(self):
        ecs = ecs_client()
        ecs.describe_services.return_value = {"services": [service(desired=0)]}
        with patch.object(deployment, "wait_service"), patch.object(deployment, "check_health"):
            deployment.deploy(ecs, config(), DIGEST)
        self.assertEqual(1, ecs.update_service.call_args.kwargs["desiredCount"])

    def test_public_health_failure_restores_previous_revision_and_fails(self):
        ecs = ecs_client()
        with patch.object(deployment, "wait_service"), patch.object(deployment, "check_health", side_effect=deployment.DeploymentError("health failed")), self.assertRaises(deployment.DeploymentError):
            deployment.deploy(ecs, config(), DIGEST)
        updates = [c.kwargs for c in ecs.update_service.call_args_list]
        self.assertEqual(["application", "old"], [u["taskDefinition"] for u in updates])
        self.assertEqual(2, updates[1]["desiredCount"])

    def test_automatic_ecs_rollback_is_never_reported_as_success(self):
        ecs = ecs_client()
        ecs.describe_services.side_effect = [{"services": [service("new", "IN_PROGRESS")]}, {"services": [service("old")]}]
        with patch.object(deployment.time, "sleep"), self.assertRaisesRegex(deployment.DeploymentError, "rolled back"):
            deployment.wait_service(ecs, config(), "new", 2)

    def test_service_update_propagation_does_not_trigger_false_rollback(self):
        ecs = ecs_client()
        ecs.describe_services.side_effect = [{"services": [service("old")]}, {"services": [service("new")]}]
        with patch.object(deployment.time, "sleep"):
            deployment.wait_service(ecs, config(), "new", 2)

    def test_concurrent_rollout_is_rejected_before_migration(self):
        ecs = ecs_client()
        ecs.describe_services.return_value = {"services": [service(state="IN_PROGRESS")]}
        with self.assertRaises(deployment.DeploymentError):
            deployment.deploy(ecs, config(), DIGEST)
        ecs.run_task.assert_not_called()

    def test_no_listener_or_service_rejects_deploy_before_any_aws_change(self):
        for changes in [{"api_url": None}, {"service_created": False}]:
            ecs = ecs_client()
            with self.subTest(changes=changes), self.assertRaises(deployment.DeploymentError):
                deployment.deploy(ecs, config() | changes, DIGEST)
            ecs.register_task_definition.assert_not_called()

    def test_retry_reuses_immutable_images_without_rebuilding_or_logging_in(self):
        ecr = MagicMock()
        ecr.describe_images.return_value = {"imageDetails": [{"imageDigest": DIGEST}]}
        with patch.object(deployment.subprocess, "run") as docker:
            deployment.publish(config(), ecr, Path("."), Path(".infra"), REVISION, REVISION)
        docker.assert_not_called()
        ecr.get_authorization_token.assert_not_called()

    def test_ecr_access_denied_does_not_attempt_build_or_push(self):
        ecr = MagicMock()
        ecr.describe_images.side_effect = ClientError({"Error": {"Code": "AccessDeniedException"}}, "DescribeImages")
        with patch.object(deployment.subprocess, "run") as docker, self.assertRaises(ClientError):
            deployment.publish(config(), ecr, Path("."), Path(".infra"), REVISION, REVISION)
        docker.assert_not_called()

    def test_new_images_build_for_fargate_architecture_and_login_token_is_stdin_only(self):
        import base64
        ecr = MagicMock()
        missing = ClientError({"Error": {"Code": "ImageNotFoundException"}}, "DescribeImages")
        ecr.describe_images.side_effect = [missing, {"imageDetails": [{"imageDigest": DIGEST}]},
                                           {"imageDetails": [{"imageDigest": DIGEST}]}]
        ecr.get_authorization_token.return_value = {"authorizationData": [{
            "authorizationToken": base64.b64encode(b"AWS:sensitive-registry-token").decode()}]}
        with patch.object(deployment.subprocess, "run") as docker:
            deployment.publish(config(), ecr, Path("."), Path(".infra"), REVISION, REVISION)
        login, build, push = docker.call_args_list
        self.assertEqual("sensitive-registry-token", login.kwargs["input"])
        self.assertNotIn("sensitive-registry-token", repr(login.args))
        self.assertIn("linux/amd64", build.args[0])
        self.assertEqual(["docker", "push"], push.args[0][:2])

    def test_service_change_during_migration_aborts_rollout(self):
        ecs = ecs_client()
        ecs.describe_services.side_effect = [{"services": [service("old")]}, {"services": [service("someone-elses-release")]}]
        with self.assertRaisesRegex(deployment.DeploymentError, "Service changed"):
            deployment.deploy(ecs, config(), DIGEST)
        ecs.update_service.assert_not_called()

    def test_http_200_without_up_status_is_not_healthy(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = json.dumps({"status": "DOWN"}).encode()
        with patch.object(deployment.urllib.request, "urlopen", return_value=response), self.assertRaises(deployment.DeploymentError):
            deployment.check_health("https://api.example.com", attempts=1)
