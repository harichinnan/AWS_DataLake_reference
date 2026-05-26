FROM public.ecr.aws/docker/library/python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    DBT_PROFILES_DIR=/opt/dbt \
    DBT_PROJECT_DIR=/opt/dbt

# git is needed by `dbt deps`; curl + unzip for the AWS CLI installer that
# entrypoint.sh uses to fetch the project tarball from S3.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl unzip ca-certificates \
 && curl -sSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscli.zip \
 && unzip -q /tmp/awscli.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscli.zip /var/lib/apt/lists/*

WORKDIR /opt/dbt

# Pipeline code is NOT baked into the image. The entrypoint pulls the dbt
# project tarball from S3 (DBT_PROJECT_S3_URI) at runtime, so the image only
# rebuilds when Dockerfile / requirements / entrypoint change.
COPY docker/dbt-runner/entrypoint.sh /opt/entrypoint.sh
COPY docker/dbt-runner/requirements.txt /tmp/requirements.txt

RUN pip install --no-cache-dir -r /tmp/requirements.txt \
 && chmod +x /opt/entrypoint.sh

ENTRYPOINT ["/opt/entrypoint.sh"]
