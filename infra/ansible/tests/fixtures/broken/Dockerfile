# Broken release for the local rollback test. Built on top of the good app image
# so it has the same runtime, user and port; only the entrypoint changes.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG BROKEN_MODE=health500
ENV BROKEN_MODE=${BROKEN_MODE}
COPY broken_app.py /opt/broken/broken_app.py
# Exec form: no shell needed in the base image. HEALTHCHECK is inherited.
ENTRYPOINT ["python", "/opt/broken/broken_app.py"]
CMD []
