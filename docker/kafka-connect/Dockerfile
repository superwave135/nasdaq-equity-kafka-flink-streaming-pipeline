###############################################################################
# Kafka Connect — S3 Sink Connector
# Base: confluentinc/cp-kafka-connect:7.6.0
###############################################################################
FROM confluentinc/cp-kafka-connect:7.6.0

# Install the Confluent S3 Sink Connector
RUN confluent-hub install --no-prompt confluentinc/kafka-connect-s3:10.5.7

# Copy entrypoint that starts Connect, waits for REST API, registers connector
COPY docker/kafka-connect/entrypoint.sh /opt/kafka-connect/entrypoint.sh

USER root
RUN chmod +x /opt/kafka-connect/entrypoint.sh
USER appuser

# REST API port
EXPOSE 8083

# Override CMD to use our entrypoint (starts worker + registers connector)
ENTRYPOINT ["/opt/kafka-connect/entrypoint.sh"]
