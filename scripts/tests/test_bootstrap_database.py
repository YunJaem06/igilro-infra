import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from botocore.exceptions import ClientError

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests"))
from support import FakeSecrets, bootstrap, config


class BootstrapUnitTest(unittest.TestCase):
    def test_role_password_is_generated_once_and_reused(self):
        client, settings = FakeSecrets(), config()
        first = bootstrap.role_secret(client, "test/application", settings, "igilro_app")
        second = bootstrap.role_secret(client, "test/application", settings, "igilro_app")
        self.assertEqual(first, second)
        self.assertGreaterEqual(len(first["password"]), 32)
        self.assertEqual(["test/application"], client.writes)

    def test_existing_secret_for_another_database_is_never_overwritten(self):
        client, settings = FakeSecrets(), config()
        bootstrap.role_secret(client, "test/application", settings, "igilro_app")
        before = client.snapshot()
        with self.assertRaises(bootstrap.BootstrapError):
            bootstrap.role_secret(client, "test/application", settings | {"database": "other"}, "igilro_app")
        self.assertEqual(before, client.values)

    def test_access_denied_is_not_treated_as_an_empty_secret(self):
        client = FakeSecrets()
        error = ClientError({"Error": {"Code": "AccessDeniedException", "Message": "Denied"}}, "GetSecretValue")
        with patch.object(client, "get_secret_value", side_effect=error), self.assertRaises(ClientError):
            bootstrap.role_secret(client, "test/application", config(), "igilro_app")
        self.assertEqual([], client.writes)

    def test_invalid_config_is_rejected_before_any_external_call(self):
        for changes in ({"application_username": "postgres"}, {"database": 'igilro;DROP DATABASE x'},
                        {"port": True}, {"host": "host?sslmode=disable"}, {"secrets": {"admin": "same", "migration": "same", "application": "same"}}):
            with self.subTest(changes=changes), self.assertRaises(bootstrap.BootstrapError):
                bootstrap.validate_config(config() | changes)

    def test_malformed_secret_is_rejected(self):
        client = FakeSecrets()
        with patch.object(client, "get_secret_value", return_value={"SecretString": "[]"}), self.assertRaises(bootstrap.BootstrapError):
            bootstrap.read_secret(client, "test/admin")

    def test_cli_failure_does_not_print_password_or_secret_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(config()))
            output = io.StringIO()
            error = bootstrap.psycopg.OperationalError("sensitive-test-password")
            with patch.object(bootstrap.boto3, "client", return_value=FakeSecrets()), patch.object(bootstrap, "bootstrap", side_effect=error), contextlib.redirect_stderr(output):
                status = bootstrap.main(["--config", str(path), "--ssl-root-cert", "unused.pem"])
            self.assertEqual(1, status)
            self.assertNotIn("sensitive-test-password", output.getvalue())
            self.assertIn("connection-error", output.getvalue())
