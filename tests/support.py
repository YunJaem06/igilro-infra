import copy
import importlib.util
import json
from pathlib import Path

from botocore.exceptions import ClientError

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bootstrap_database", ROOT / "scripts/bootstrap_database.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


def config():
    return {"region": "ap-northeast-2", "host": "localhost", "port": 5432, "database": "igilro",
            "admin_username": "postgres", "migration_username": "igilro_migrator", "application_username": "igilro_app",
            "secrets": {"admin": "test/admin", "migration": "test/migration", "application": "test/application"}}


class FakeSecrets:
    def __init__(self, admin_password="test-admin-password"):
        self.values = {"test/admin": {"username": "postgres", "password": admin_password}}
        self.writes = []

    def get_secret_value(self, SecretId):
        if SecretId not in self.values:
            raise ClientError({"Error": {"Code": "ResourceNotFoundException", "Message": "No current version"}}, "GetSecretValue")
        return {"SecretString": json.dumps(self.values[SecretId])}

    def put_secret_value(self, SecretId, SecretString):
        if SecretId not in ("test/migration", "test/application"):
            raise AssertionError("Unexpected secret write")
        self.values[SecretId] = json.loads(SecretString)
        self.writes.append(SecretId)

    def snapshot(self):
        return copy.deepcopy(self.values)
