###############################################################################
# Flink JobManager
# Base: flink:1.19-scala_2.12
###############################################################################
FROM flink:1.19-scala_2.12

# Install Python + PyFlink dependencies + curl for health checks
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip curl && \
    ln -s /usr/bin/python3 /usr/bin/python && \
    pip3 install --no-cache-dir apache-flink==1.19.0 && \
    rm -rf /var/lib/apt/lists/*

# Download Kafka SQL connector JAR (needed for KafkaSource / KafkaSink)
ADD https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.3.0-1.19/flink-sql-connector-kafka-3.3.0-1.19.jar /opt/flink/lib/
RUN chmod 644 /opt/flink/lib/flink-sql-connector-kafka-3.3.0-1.19.jar

# Copy the Flink job (build context = project root)
COPY flink/jobs/stock_tick_processor.py /opt/flink/jobs/stock_tick_processor.py

# Copy entrypoint that starts JM, waits for REST API, then submits the job
COPY docker/flink-jobmanager/entrypoint.sh /opt/flink/entrypoint.sh
RUN chmod +x /opt/flink/entrypoint.sh

# REST + RPC + Blob ports
EXPOSE 8081 6123 6124

# ECS task definition provides CMD ["jobmanager"] which is passed as $@ to entrypoint
ENTRYPOINT ["/opt/flink/entrypoint.sh"]
