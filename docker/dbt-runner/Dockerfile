FROM public.ecr.aws/docker/library/python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    DBT_PROFILES_DIR=/opt/dbt

RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/dbt

COPY dbt/ /opt/dbt/
COPY docker/dbt-runner/entrypoint.sh /opt/entrypoint.sh
COPY docker/dbt-runner/requirements.txt /tmp/requirements.txt

RUN pip install --no-cache-dir -r /tmp/requirements.txt \
 && chmod +x /opt/entrypoint.sh

ENTRYPOINT ["/opt/entrypoint.sh"]
