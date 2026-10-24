#!/usr/bin/env python3
"""Prepare PostGIS and DB roles from Secrets Manager; never run Terraform or Flyway."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import sys

import boto3
from botocore.exceptions import BotoCoreError, ClientError
import psycopg
from psycopg import sql


class BootstrapError(Exception):
    """Safe, credential-free operator message."""


def validate_config(config):
    if not isinstance(config, dict):
        raise BootstrapError("Configuration must be a JSON object")
    for key in ("database", "admin_username", "migration_username", "application_username"):
        if not isinstance(config.get(key), str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,62}", config[key]):
            raise BootstrapError("Invalid database or role identifier")
    if len({config[k] for k in ("admin_username", "migration_username", "application_username")}) != 3:
        raise BootstrapError("Administrator, migration and application roles must be different")
    if not isinstance(config.get("host"), str) or not re.fullmatch(r"[A-Za-z0-9.-]{1,253}", config["host"]):
        raise BootstrapError("Invalid database hostname")
    if type(config.get("port")) is not int or not 1 <= config["port"] <= 65535:
        raise BootstrapError("Invalid database port")
    if not isinstance(config.get("region"), str) or not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-\d+", config["region"]):
        raise BootstrapError("Invalid AWS region")
    identifiers = config.get("secrets", {})
    if not isinstance(identifiers, dict) or set(identifiers) != {"admin", "migration", "application"} or not all(isinstance(identifiers.get(k), str) and identifiers[k] for k in ("admin", "migration", "application")):
        raise BootstrapError("Three secret identifiers are required")
    if len(set(identifiers.values())) != 3:
        raise BootstrapError("Each role must have a separate secret")


def read_secret(client, identifier):
    response = client.get_secret_value(SecretId=identifier)
    try:
        value = json.loads(response["SecretString"])
    except (KeyError, TypeError, ValueError):
        raise BootstrapError("Secret must contain a JSON object") from None
    if not isinstance(value, dict):
        raise BootstrapError("Secret must contain a JSON object")
    return value


def role_secret(client, identifier, config, username):
    expected = {"engine": "postgres", "host": config["host"], "port": config["port"],
                "dbname": config["database"], "username": username}
    try:
        value = read_secret(client, identifier)
    except ClientError as error:
        if error.response["Error"]["Code"] != "ResourceNotFoundException":
            raise
        # Terraform must already have created the secret metadata. Never create a
        # different secret on typo/permission errors. The database advisory lock
        # serializes this read/write sequence across bootstrap runs.
        value = expected | {"password": secrets.token_urlsafe(32)}
        client.put_secret_value(SecretId=identifier, SecretString=json.dumps(value))
    if any(value.get(k) != v for k, v in expected.items()):
        raise BootstrapError("Existing role secret targets a different database or role")
    if not isinstance(value.get("password"), str) or len(value["password"]) < 32:
        raise BootstrapError("Role secret requires a password of at least 32 characters")
    return value


def connect(config, credentials, ca_file):
    return psycopg.connect(host=config["host"], port=config["port"], dbname=config["database"],
                           user=credentials["username"], password=credentials["password"],
                           sslmode="verify-full", sslrootcert=str(ca_file), connect_timeout=10,
                           options="-c statement_timeout=60000 -c lock_timeout=30000", autocommit=True)


def check_existing_role(connection, username):
    role = connection.execute(
        "SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, "
        "EXISTS(SELECT 1 FROM pg_auth_members WHERE member=r.oid) FROM pg_roles r WHERE rolname=%s",
        (username,),
    ).fetchone()
    if role and (not role[0] or any(role[1:])):
        raise BootstrapError("Existing managed role has unexpected privileges or memberships")
    return role is not None


def set_role(connection, credentials, exists):
    # Send a SCRAM verifier instead of a plaintext password in SQL. The verifier
    # still is sensitive and must never be printed or included in diagnostics.
    verifier = connection.pgconn.encrypt_password(credentials["password"].encode(),
                                                credentials["username"].encode(), b"scram-sha-256").decode()
    operation = "ALTER" if exists else "CREATE"
    connection.execute(sql.SQL(operation + " ROLE {} LOGIN NOINHERIT PASSWORD {}").format(
        sql.Identifier(credentials["username"]), sql.Literal(verifier)))


def bootstrap(config, client, ca_file):
    validate_config(config)
    if not Path(ca_file).is_file():
        raise BootstrapError("TLS CA certificate file is required")
    admin = read_secret(client, config["secrets"]["admin"])
    if admin.get("username") != config["admin_username"] or not isinstance(admin.get("password"), str) or not admin["password"]:
        raise BootstrapError("Administrator secret has invalid credentials")
    with connect(config, admin, ca_file) as connection:
        connection.execute("SELECT pg_advisory_lock(73694118)")
        exists = {role: check_existing_role(connection, config[role + "_username"])
                  for role in ("migration", "application")}
        owns_objects = connection.execute(
            "SELECT EXISTS(SELECT 1 FROM pg_class WHERE relowner=%s::regrole) OR "
            "EXISTS(SELECT 1 FROM pg_namespace WHERE nspowner=%s::regrole) OR "
            "EXISTS(SELECT 1 FROM pg_database WHERE datdba=%s::regrole)",
            (config["application_username"],) * 3,
        ).fetchone()[0] if exists["application"] else False
        if owns_objects:
            raise BootstrapError("Application role owns database objects; explicit ownership repair is required")
        credentials = {role: role_secret(client, config["secrets"][role], config, config[role + "_username"])
                       for role in ("migration", "application")}
        migration = sql.Identifier(config["migration_username"])
        application = sql.Identifier(config["application_username"])
        database = sql.Identifier(config["database"])
        with connection.transaction():
            connection.execute("CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public")
            for role in ("migration", "application"):
                set_role(connection, credentials[role], exists[role])
            connection.execute(sql.SQL("REVOKE ALL ON DATABASE {} FROM PUBLIC").format(database))
            connection.execute(sql.SQL("REVOKE ALL ON DATABASE {} FROM {}").format(database, application))
            connection.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
            connection.execute(sql.SQL("REVOKE CREATE ON SCHEMA public FROM {}").format(application))
            connection.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}, {}").format(database, migration, application))
            connection.execute(sql.SQL("GRANT USAGE, CREATE ON SCHEMA public TO {}").format(migration))
            connection.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(application))
            connection.execute(sql.SQL("GRANT SELECT ON public.spatial_ref_sys TO {}, {}").format(migration, application))
        with connect(config, credentials["migration"], ca_file) as migrator:
            with migrator.transaction():
                migrator.execute(sql.SQL("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO {}").format(application))
                # RDS administrators aren't true PostgreSQL superusers. Reapply
                # grants as the table owner, rather than assuming admin can change
                # permissions on objects created by the migration account.
                tables = migrator.execute("SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                                          "WHERE n.nspname='public' AND c.relowner=current_user::regrole "
                                          "AND c.relkind IN ('r','p','v','m','f')").fetchall()
                for (table,) in tables:
                    identifier = sql.Identifier("public", table)
                    migrator.execute(sql.SQL("REVOKE ALL ON TABLE {} FROM {}").format(identifier, application))
                    migrator.execute(sql.SQL("GRANT SELECT ON TABLE {} TO {}").format(identifier, application))
        version = connection.execute("SELECT PostGIS_Lib_Version()").fetchone()[0]
        # Closing this session also releases the advisory lock on every error path.
    return {"status": "ready", "database": config["database"], "postgisVersion": version}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--config", type=Path, help="Non-secret Terraform database_bootstrap output JSON")
    source.add_argument("--config-env", help="Environment variable containing the same non-secret JSON (for one-off tasks)")
    parser.add_argument("--ssl-root-cert", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        config = json.loads(args.config.read_text() if args.config else os.environ[args.config_env])
        validate_config(config)
        client = boto3.client("secretsmanager", region_name=config["region"])
        print(json.dumps(bootstrap(config, client, args.ssl_root_cert)))
        return 0
    except BootstrapError as error:
        print(str(error), file=sys.stderr)
    except ClientError as error:
        print("Secrets Manager request failed: " + error.response["Error"]["Code"], file=sys.stderr)
    except BotoCoreError as error:
        print("AWS credential or transport error: " + type(error).__name__, file=sys.stderr)
    except psycopg.Error as error:
        print("Database initialization failed; SQLSTATE=" + (error.sqlstate or "connection-error"), file=sys.stderr)
    except (OSError, ValueError, TypeError, KeyError):
        print("Invalid initialization input or certificate file", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
