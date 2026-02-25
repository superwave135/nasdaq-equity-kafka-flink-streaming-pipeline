###############################################################################
# Kafka KRaft — Single-Node Broker + Controller
# Base: apache/kafka:3.7.0 (includes KRaft support, no ZooKeeper)
###############################################################################
FROM apache/kafka:3.7.0

USER root

# Copy KRaft broker config (build context = project root)
COPY kafka/config/kraft-broker.properties /opt/kafka/config/kraft/server.properties

# Entrypoint script: format storage, create topics, start broker
COPY docker/kafka/entrypoint.sh /opt/kafka/entrypoint.sh
RUN chmod +x /opt/kafka/entrypoint.sh

# Kafka data on EFS mount
VOLUME ["/var/kafka/data"]

# Broker + Controller ports
EXPOSE 9092 9093

# Ensure data dir + config owned by UID 1000 (matches EFS access point)
RUN chown -R 1000:1000 /opt/kafka /var/kafka/data 2>/dev/null || true

# Use numeric UID:GID — Fargate cannot resolve usernames during EFS mount
USER 1000:1000

ENTRYPOINT ["/opt/kafka/entrypoint.sh"]
