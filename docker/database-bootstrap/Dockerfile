# Official multi-architecture Python index: linux/arm64 and linux/amd64.
FROM python:3.12-slim-bookworm@sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70
WORKDIR /app
COPY scripts/requirements-database.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt \
    && groupadd --gid 10001 igilro && useradd --uid 10001 --gid 10001 --no-create-home igilro
COPY scripts/bootstrap_database.py ./bootstrap_database.py
COPY docker/database-bootstrap/rds-ca.crt ./certs/rds-ca.pem
USER 10001:10001
ENTRYPOINT ["python", "/app/bootstrap_database.py"]
