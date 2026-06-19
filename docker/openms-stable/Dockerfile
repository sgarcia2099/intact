ARG OPENMS_VERSION=3.4.1
ARG OPENMS_BASE_IMAGE=ghcr.io/openms/openms-executables:${OPENMS_VERSION}

FROM ${OPENMS_BASE_IMAGE}

ARG OPENMS_VERSION
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="OpenMS FLASHDeconv (stable pin)" \
      org.opencontainers.image.description="Pinned OpenMS/FLASHDeconv runtime image for the intact pipeline" \
      org.opencontainers.image.version="${OPENMS_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/openms/OpenMS"

ENTRYPOINT ["/opt/OpenMS/bin/FLASHDeconv"]
CMD ["--help"]
