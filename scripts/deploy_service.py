#!/usr/bin/env python3
"""Publish immutable images or run private ECS initialization/migration/deployment."""
import argparse
import base64
import copy
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

import boto3
from botocore.exceptions import BotoCoreError, ClientError


class DeploymentError(RuntimeError):
    pass


def validate_revision(value):
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise argparse.ArgumentTypeError("A full Git commit SHA is required")
    return value


def image_digest(ecr, repository, revision, missing_ok=False):
    try:
        response = ecr.describe_images(repositoryName=repository["name"], imageIds=[{"imageTag": revision}])
    except ClientError as error:
        if missing_ok and error.response["Error"]["Code"] == "ImageNotFoundException":
            return None
        raise
    details = response.get("imageDetails", [])
    digest = details[0].get("imageDigest", "") if len(details) == 1 else ""
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise DeploymentError("ECR did not return one immutable image digest")
    return digest


def publish(config, ecr, server_source, infra_source, server_revision, infra_revision):
    sources = {"server": (server_source, server_revision, "Dockerfile"),
               "bootstrap": (infra_source, infra_revision, "docker/database-bootstrap/Dockerfile")}
    for role, (source, revision, dockerfile) in sources.items():
        repository = config["repositories"][role]
        digest = image_digest(ecr, repository, revision, missing_ok=True)
        if digest is None:
            # Login only to our account's registry, with the token on stdin and no credential logging.
            registry = repository["url"].split("/")[0]
            credentials = ecr.get_authorization_token(registryIds=[config["account_id"]])["authorizationData"][0]
            user, password = base64.b64decode(credentials["authorizationToken"]).decode().split(":", 1)
            subprocess.run(["docker", "login", "--username", user, "--password-stdin", registry],
                           input=password, text=True, capture_output=True, check=True)
            image = repository["url"] + ":" + revision
            subprocess.run(["docker", "build", "--platform", "linux/amd64", "--tag", image,
                            "--file", str(Path(source) / dockerfile), str(source)], check=True)
            subprocess.run(["docker", "push", image], check=True)
            digest = image_digest(ecr, repository, revision)
        print(f"{role} image: {repository['url']}@{digest}")


def register_task(ecs, config, role, digest):
    task = copy.deepcopy(config["tasks"][role])
    repository = config["repositories"]["bootstrap" if role == "bootstrap" else "server"]
    task["containerDefinitions"][0]["image"] = repository["url"] + "@" + digest
    return ecs.register_task_definition(**task)["taskDefinition"]["taskDefinitionArn"]


def run_once(ecs, config, definition, role, timeout=900):
    task_arn, stopped = None, False
    try:
        result = ecs.run_task(cluster=config["cluster"], taskDefinition=definition, count=1,
                              launchType="FARGATE", platformVersion="1.4.0",
                              networkConfiguration=config["network"], clientToken=str(uuid.uuid4()))
        tasks = result.get("tasks", [])
        task_arn = tasks[0]["taskArn"] if len(tasks) == 1 else None
        if result.get("failures") or task_arn is None:
            raise DeploymentError(f"{role} task could not be started")
        print(f"{role} task: {task_arn}")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = ecs.describe_tasks(cluster=config["cluster"], tasks=[task_arn])
            described = state.get("tasks", [])
            if described and described[0].get("lastStatus") == "STOPPED":
                stopped = True
                task = described[0]
                containers = task.get("containers", [])
                if (task.get("stopCode") == "EssentialContainerExited" and len(containers) == 1
                        and containers[0].get("name") == role and containers[0].get("exitCode") == 0):
                    print(f"{role} task succeeded")
                    return
                raise DeploymentError(f"{role} task failed; inspect its CloudWatch log and ECS stopped reason")
            # ECS can briefly return MISSING immediately after RunTask (eventual consistency).
            time.sleep(10)
        raise DeploymentError(f"{role} task timed out")
    finally:
        if task_arn and not stopped:
            try:
                ecs.stop_task(cluster=config["cluster"], task=task_arn, reason="Deployment interrupted or timed out")
            except (ClientError, BotoCoreError):
                print("Could not stop the one-off task; inspect ECS before retrying", file=sys.stderr)


def describe_service(ecs, config):
    response = ecs.describe_services(cluster=config["cluster"], services=[config["service"]])
    services = response.get("services", [])
    if response.get("failures") or len(services) != 1 or services[0].get("status") != "ACTIVE":
        raise DeploymentError("Create the idle ECS service with Terraform after publishing the first image")
    return services[0]


def wait_service(ecs, config, definition, desired_count, timeout=1200):
    deadline = time.monotonic() + timeout
    propagation_deadline = time.monotonic() + 60
    observed = False
    while time.monotonic() < deadline:
        service = describe_service(ecs, config)
        deployments = service.get("deployments", [])
        primary = next((d for d in deployments if d.get("status") == "PRIMARY"), {})
        if primary.get("taskDefinition") != definition:
            if observed or time.monotonic() >= propagation_deadline:
                raise DeploymentError("ECS deployment failed or rolled back to another revision")
            time.sleep(10)
            continue
        observed = True
        if primary.get("rolloutState") == "FAILED":
            raise DeploymentError("ECS deployment failed or rolled back to another revision")
        if (len(deployments) == 1 and primary.get("rolloutState") == "COMPLETED"
                and service.get("taskDefinition") == definition
                and service.get("desiredCount") == desired_count
                and service.get("runningCount") == desired_count and service.get("pendingCount") == 0):
            return
        time.sleep(10)
    raise DeploymentError("ECS deployment did not become healthy in time")


def check_health(api_url, attempts=6):
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(api_url.rstrip("/") + "/api/v1/health",
                                             headers={"User-Agent": "igilro-deployment"})
            with urllib.request.urlopen(request, timeout=10) as response:
                body = json.loads(response.read(65536))
                if response.status == 200 and isinstance(body, dict) and body.get("status") == "UP":
                    return
        except (OSError, ValueError, urllib.error.URLError):
            pass
        if attempt + 1 < attempts:
            time.sleep(10)
    raise DeploymentError("Public API health check failed")


def deploy(ecs, config, digest):
    if not config.get("service_created") or not config.get("api_url"):
        raise DeploymentError("Configure the API listener/DNS and create the idle ECS service before deploy")
    previous = describe_service(ecs, config)
    if any(d.get("rolloutState") == "IN_PROGRESS" for d in previous.get("deployments", [])):
        raise DeploymentError("Another ECS rollout is active; wait before deploying")
    migration = register_task(ecs, config, "migration", digest)
    run_once(ecs, config, migration, "migration")
    # Migration and application use the very same immutable server artifact.
    application = register_task(ecs, config, "application", digest)
    current = describe_service(ecs, config)
    if current["taskDefinition"] != previous["taskDefinition"] or current["desiredCount"] != previous["desiredCount"]:
        raise DeploymentError("Service changed while migration ran; deployment stopped")
    desired = max(previous["desiredCount"], 1)
    try:
        ecs.update_service(cluster=config["cluster"], service=config["service"],
                           taskDefinition=application, desiredCount=desired)
        wait_service(ecs, config, application, desired)
        check_health(config["api_url"])
    except (DeploymentError, ClientError, BotoCoreError):
        print("Deployment failed; restoring the previous service revision/count (database is not rolled back)", file=sys.stderr)
        try:
            ecs.update_service(cluster=config["cluster"], service=config["service"],
                               taskDefinition=previous["taskDefinition"], desiredCount=previous["desiredCount"])
            wait_service(ecs, config, previous["taskDefinition"], previous["desiredCount"], timeout=600)
        except (DeploymentError, ClientError, BotoCoreError):
            print("Service rollback needs operator attention; inspect ECS events and CloudWatch", file=sys.stderr)
        raise
    print(f"Deployment succeeded: {application}; health: {config['api_url']}/api/v1/health")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--operation", choices=["publish", "bootstrap", "deploy"], required=True)
    parser.add_argument("--parameter", required=True)
    parser.add_argument("--server-revision", type=validate_revision, required=True)
    parser.add_argument("--infra-revision", type=validate_revision, required=True)
    parser.add_argument("--server-source", type=Path, default=Path("."))
    parser.add_argument("--infra-source", type=Path, default=Path(".infra"))
    args = parser.parse_args(argv)
    try:
        session = boto3.Session()
        config = json.loads(session.client("ssm").get_parameter(Name=args.parameter)["Parameter"]["Value"])
        account = session.client("sts").get_caller_identity()["Account"]
        if config.get("version") != 1 or config.get("account_id") != account or config.get("region") != session.region_name:
            raise DeploymentError("Deployment configuration version, AWS account or region mismatch")
        ecr = session.client("ecr")
        if args.operation == "publish":
            publish(config, ecr, args.server_source, args.infra_source, args.server_revision, args.infra_revision)
        else:
            ecs = session.client("ecs")
            role = "bootstrap" if args.operation == "bootstrap" else "server"
            revision = args.infra_revision if role == "bootstrap" else args.server_revision
            digest = image_digest(ecr, config["repositories"][role], revision)
            if role == "bootstrap":
                run_once(ecs, config, register_task(ecs, config, role, digest), role)
            else:
                deploy(ecs, config, digest)
        return 0
    except DeploymentError as error:
        print(str(error), file=sys.stderr)
    except ClientError as error:
        print("AWS request failed: " + error.response["Error"]["Code"], file=sys.stderr)
    except BotoCoreError as error:
        print("AWS transport/credential failure: " + type(error).__name__, file=sys.stderr)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        print("Invalid deployment configuration or failed Docker command", file=sys.stderr)
    return 1


def interrupted(_signum, _frame):
    raise DeploymentError("Deployment interrupted; inspect ECS before retrying")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    raise SystemExit(main())
