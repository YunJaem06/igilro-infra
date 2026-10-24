#!/usr/bin/env python3
"""Run the versioned server JAR as a one-off Flyway job using its migration secret."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import quote

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from bootstrap_database import BootstrapError, read_secret, validate_config


def run_migration(config, client, ca_file, server_jar, java="java"):
    validate_config(config)
    if not Path(ca_file).is_file() or not Path(server_jar).is_file():
        raise BootstrapError("An existing CA certificate and server JAR are required")
    credentials = read_secret(client, config["secrets"]["migration"])
    expected = {"engine":"postgres", "host":config["host"], "port":config["port"],
                "dbname":config["database"], "username":config["migration_username"]}
    if any(credentials.get(k) != v for k, v in expected.items()) or not isinstance(credentials.get("password"), str) or len(credentials["password"]) < 32:
        raise BootstrapError("Migration secret is invalid; run database bootstrap first")
    env = {k:os.environ[k] for k in ("PATH", "JAVA_HOME", "LANG", "TMPDIR") if k in os.environ}
    env.update(DB_URL=f"jdbc:postgresql://{config['host']}:{config['port']}/{config['database']}?sslmode=verify-full&sslrootcert={quote(str(Path(ca_file).resolve()), safe='/')}&connectTimeout=10",
               DB_USERNAME=credentials["username"], DB_PASSWORD=credentials["password"],
               SPRING_PROFILES_ACTIVE="prod", SPRING_MAIN_WEB_APPLICATION_TYPE="none", SPRING_FLYWAY_ENABLED="true")
    result = subprocess.run([java, "-jar", str(Path(server_jar).resolve())], env=env,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
    print(result.stdout.replace(credentials["password"], "[REDACTED]"), end="")
    return result.returncode


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--ssl-root-cert", type=Path, required=True)
    parser.add_argument("--server-jar", type=Path, required=True)
    parser.add_argument("--java", default="java")
    args = parser.parse_args(argv)
    try:
        config = json.loads(args.config.read_text())
        validate_config(config)
        return run_migration(config, boto3.client("secretsmanager", region_name=config["region"]),
                             args.ssl_root_cert, args.server_jar, args.java)
    except BootstrapError as error:
        print(str(error), file=sys.stderr)
    except ClientError as error:
        print("Secrets Manager request failed: " + error.response["Error"]["Code"], file=sys.stderr)
    except BotoCoreError as error:
        print("AWS credential or transport error: " + type(error).__name__, file=sys.stderr)
    except subprocess.TimeoutExpired:
        print("Migration timed out; inspect the database before retrying", file=sys.stderr)
    except (OSError, ValueError, TypeError):
        print("Invalid migration input or Java executable", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
