import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests"))
from support import FakeSecrets, bootstrap, config
import run_flyway


class FlywayRunnerTest(unittest.TestCase):
    def test_password_is_only_passed_via_environment_and_failure_status_is_preserved(self):
        settings, client = config(), FakeSecrets()
        credentials = bootstrap.role_secret(client, "test/migration", settings, "igilro_migrator")
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            ca, jar = Path(directory)/"ca.crt", Path(directory)/"server.jar"
            ca.touch()
            jar.touch()
            result = subprocess.CompletedProcess([], 7, "failure: " + credentials["password"])
            with patch.object(run_flyway.subprocess, "run", return_value=result) as launch, contextlib.redirect_stdout(output):
                self.assertEqual(7, run_flyway.run_migration(settings, client, ca, jar))
            args, kwargs = launch.call_args
            self.assertNotIn(credentials["password"], repr(args))
            self.assertEqual(credentials["password"], kwargs["env"]["DB_PASSWORD"])
            self.assertEqual("none", kwargs["env"]["SPRING_MAIN_WEB_APPLICATION_TYPE"])
            self.assertEqual("true", kwargs["env"]["SPRING_FLYWAY_ENABLED"])
            self.assertNotIn(credentials["password"], output.getvalue())
            self.assertIn("[REDACTED]", output.getvalue())

    def test_migration_does_not_create_a_missing_secret_or_start_java(self):
        with tempfile.TemporaryDirectory() as directory:
            ca, jar = Path(directory)/"ca.crt", Path(directory)/"server.jar"
            ca.touch()
            jar.touch()
            client = FakeSecrets()
            with patch.object(run_flyway.subprocess, "run") as launch, self.assertRaises(bootstrap.ClientError):
                run_flyway.run_migration(config(), client, ca, jar)
            launch.assert_not_called()
            self.assertEqual([], client.writes)
