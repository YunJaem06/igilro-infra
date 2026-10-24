import json
import contextlib
import io
import os
from pathlib import Path
import secrets
import subprocess
import socket
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

import psycopg

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from support import FakeSecrets, bootstrap, config
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import run_flyway


class DatabaseInitializationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jar = Path(os.environ["IGILRO_SERVER_JAR"]).resolve()
        if not cls.jar.is_file():
            raise RuntimeError("Build igilro-server bootJar and set IGILRO_SERVER_JAR")
        cls.directory = tempfile.TemporaryDirectory(prefix="igilro-database-test-")
        cls.ca = Path(cls.directory.name) / "ca.crt"
        cls.name = "igilro-db-test-" + secrets.token_hex(4)
        cls.admin_password = secrets.token_urlsafe(32)
        image = os.environ.get("DATABASE_TEST_IMAGE", "igilro-postgis:test")
        command = (
            "mkdir -p /test-certs && openssl req -x509 -newkey rsa:2048 -nodes -days 1 "
            "-subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' "
            "-keyout /test-certs/server.key -out /test-certs/server.crt >/dev/null 2>&1 && "
            "chown -R postgres:postgres /test-certs && chmod 600 /test-certs/server.key && "
            "exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/test-certs/server.crt "
            "-c ssl_key_file=/test-certs/server.key"
        )
        subprocess.run(["docker", "run", "-d", "--rm", "--name", cls.name, "-p", "127.0.0.1::5432",
                        "-e", "POSTGRES_DB=igilro", "-e", "POSTGRES_PASSWORD=" + cls.admin_password,
                        "--entrypoint", "sh", image, "-c", command], check=True, capture_output=True)
        cls.addClassCleanup(subprocess.run, ["docker", "rm", "-f", cls.name], capture_output=True)
        cls.addClassCleanup(cls.directory.cleanup)
        for _ in range(120):
            ready = subprocess.run(["docker", "exec", cls.name, "pg_isready", "-h", "127.0.0.1", "-U", "postgres", "-d", "igilro"], capture_output=True)
            if ready.returncode == 0:
                break
            time.sleep(0.25)
        else:
            raise RuntimeError("Temporary PostGIS did not become ready")
        subprocess.run(["docker", "cp", cls.name + ":/test-certs/server.crt", str(cls.ca)], check=True, capture_output=True)
        port = subprocess.check_output(["docker", "port", cls.name, "5432/tcp"], text=True).strip().rsplit(":", 1)[1]
        cls.settings = config() | {"host": "127.0.0.1", "port": int(port)}

    def setUp(self):
        self.client = FakeSecrets(self.admin_password)
        admin = self.client.values["test/admin"]
        with bootstrap.connect(self.settings, admin, self.ca) as connection:
            # One isolated DB per test; no developer database or global extensions are touched.
            connection.execute("DROP SCHEMA public CASCADE")
            connection.execute("CREATE SCHEMA public")
            for role in ("igilro_app", "igilro_migrator"):
                if connection.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (role,)).fetchone():
                    connection.execute(bootstrap.sql.SQL("DROP OWNED BY {}").format(bootstrap.sql.Identifier(role)))
                    connection.execute(bootstrap.sql.SQL("DROP ROLE {}").format(bootstrap.sql.Identifier(role)))

    def initialize(self):
        return bootstrap.bootstrap(self.settings, self.client, self.ca)

    def migrate(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = run_flyway.run_migration(self.settings, self.client, self.ca, self.jar)
        for value in self.client.values.values():
            self.assertNotIn(value["password"], output.getvalue())
        if status:
            self.fail("Flyway job failed: " + output.getvalue()[-4000:])

    def test_bootstrap_and_flyway_are_repeatable_and_application_is_read_only(self):
        self.assertEqual("ready", self.initialize()["status"])
        before = self.client.snapshot()
        self.migrate()
        self.assertEqual("ready", self.initialize()["status"])
        self.assertEqual(before, self.client.values)
        self.migrate()
        with bootstrap.connect(self.settings, self.client.values["test/application"], self.ca) as app:
            self.assertEqual(3, app.execute("SELECT count(*) FROM flyway_schema_history WHERE success").fetchone()[0])
            self.assertEqual(4326, app.execute("SELECT ST_SRID(ST_SetSRID(ST_MakePoint(127,37),4326))").fetchone()[0])
            self.assertEqual(0, app.execute("SELECT count(*) FROM route_dataset").fetchone()[0])
            self.assertEqual(0, app.execute("SELECT count(*) FROM building_shade_dataset").fetchone()[0])
            for statement in ("CREATE TABLE forbidden(id int)", "DELETE FROM route_dataset", "CREATE SCHEMA forbidden"):
                with self.subTest(statement=statement), self.assertRaises(psycopg.errors.InsufficientPrivilege):
                    app.execute(statement)

    def test_default_privileges_apply_to_future_migrations(self):
        self.initialize()
        with bootstrap.connect(self.settings, self.client.values["test/migration"], self.ca) as migrator:
            migrator.execute("CREATE TABLE future_route(id int)")
            migrator.execute("INSERT INTO future_route VALUES (1)")
        with bootstrap.connect(self.settings, self.client.values["test/application"], self.ca) as app:
            self.assertEqual(1, app.execute("SELECT id FROM future_route").fetchone()[0])
            with self.assertRaises(psycopg.errors.InsufficientPrivilege):
                app.execute("INSERT INTO future_route VALUES(2)")

    def test_privileged_existing_role_is_rejected_before_secret_values_are_written(self):
        with bootstrap.connect(self.settings, self.client.values["test/admin"], self.ca) as admin:
            admin.execute("CREATE ROLE igilro_app LOGIN CREATEDB")
        with self.assertRaises(bootstrap.BootstrapError):
            self.initialize()
        self.assertEqual([], self.client.writes)

    def test_tls_certificate_is_verified(self):
        bad_ca = Path(self.directory.name) / "invalid-ca.crt"
        bad_ca.write_text("not a CA certificate")
        with self.assertRaises(psycopg.OperationalError):
            bootstrap.bootstrap(self.settings, self.client, bad_ca)
        self.assertEqual([], self.client.writes)

    def test_owned_application_objects_are_not_silently_treated_as_read_only(self):
        self.initialize()
        with bootstrap.connect(self.settings, self.client.values["test/admin"], self.ca) as admin:
            admin.execute("CREATE TABLE unexpected_owner(id int)")
            admin.execute("ALTER TABLE unexpected_owner OWNER TO igilro_app")
        with self.assertRaises(bootstrap.BootstrapError):
            self.initialize()

    def test_reinitialization_does_not_require_a_true_postgres_superuser(self):
        root = self.client.values["test/admin"]
        limited_password = secrets.token_urlsafe(32)
        with bootstrap.connect(self.settings, root, self.ca) as admin:
            admin.execute(bootstrap.sql.SQL("CREATE ROLE test_admin LOGIN CREATEROLE PASSWORD {}").format(bootstrap.sql.Literal(limited_password)))
            admin.execute("CREATE EXTENSION postgis")
            admin.execute("ALTER TABLE spatial_ref_sys OWNER TO test_admin")
            admin.execute("ALTER DATABASE igilro OWNER TO test_admin")
            admin.execute("ALTER SCHEMA public OWNER TO test_admin")
        self.client.values["test/admin"] = {"username":"test_admin", "password":limited_password}
        settings = self.settings | {"admin_username":"test_admin"}
        try:
            self.assertEqual("ready", bootstrap.bootstrap(settings, self.client, self.ca)["status"])
            with bootstrap.connect(settings, self.client.values["test/migration"], self.ca) as migrator:
                migrator.execute("CREATE TABLE owner_permissions(id int)")
            self.assertEqual("ready", bootstrap.bootstrap(settings, self.client, self.ca)["status"])
            with bootstrap.connect(settings, self.client.values["test/application"], self.ca) as app:
                self.assertEqual(0, app.execute("SELECT count(*) FROM owner_permissions").fetchone()[0])
        finally:
            self.client.values["test/admin"] = root
            with bootstrap.connect(self.settings, root, self.ca) as admin:
                admin.execute("ALTER DATABASE igilro OWNER TO postgres")
                admin.execute("ALTER SCHEMA public OWNER TO postgres")
                admin.execute("ALTER TABLE spatial_ref_sys OWNER TO postgres")
                admin.execute("DROP OWNED BY test_admin")
                admin.execute("DROP ROLE test_admin")

    def test_production_app_starts_without_migration_permissions(self):
        self.initialize()
        self.migrate()
        with bootstrap.connect(self.settings, self.client.values["test/migration"], self.ca) as migrator:
            migrator.execute("REVOKE SELECT ON flyway_schema_history FROM igilro_app")
        ports = []
        for _ in range(2):
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                ports.append(listener.getsockname()[1])
        credentials = self.client.values["test/application"]
        env = dict(os.environ, DB_URL=f"jdbc:postgresql://127.0.0.1:{self.settings['port']}/igilro?sslmode=verify-full&sslrootcert={self.ca}",
                   DB_USERNAME=credentials["username"], DB_PASSWORD=credentials["password"],
                   SPRING_PROFILES_ACTIVE="prod", SPRING_FLYWAY_ENABLED="false", SPRING_MAIN_WEB_APPLICATION_TYPE="servlet",
                   SERVER_PORT=str(ports[0]), MANAGEMENT_SERVER_PORT=str(ports[1]))
        log_path = Path(self.directory.name) / "server.log"
        with log_path.open("w") as log:
            process = subprocess.Popen(["java", "-jar", str(self.jar)], env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                base = f"http://localhost:{ports[0]}"
                for _ in range(120):
                    if process.poll() is not None:
                        self.fail("Production server exited: " + log_path.read_text()[-3000:])
                    try:
                        with urllib.request.urlopen(base + "/api/v1/health", timeout=1) as response:
                            self.assertEqual("UP", json.load(response)["status"])
                            break
                    except (OSError, urllib.error.URLError):
                        time.sleep(0.25)
                else:
                    self.fail("Production server did not become ready")
                body = json.dumps({"origin": {"longitude":127.0374,"latitude":37.5445},"destination":{"longitude":127.043,"latitude":37.548}}).encode()
                request = urllib.request.Request(base + "/api/v1/routes/search", data=body, headers={"Content-Type":"application/json"})
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(request, timeout=5)
                self.assertEqual(503, error.exception.code)
                self.assertEqual("ROUTING_DATA_UNAVAILABLE", json.load(error.exception)["code"])
            finally:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for value in self.client.values.values():
            self.assertNotIn(value["password"], log_path.read_text())
