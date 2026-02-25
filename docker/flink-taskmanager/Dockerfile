###############################################################################
# Flink TaskManager
# Base: flink:1.19-scala_2.12
###############################################################################
FROM flink:1.19-scala_2.12

# Install Python + PyFlink dependencies (must match JobManager)
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip && \
    ln -s /usr/bin/python3 /usr/bin/python && \
    pip3 install --no-cache-dir apache-flink==1.19.0 && \
    rm -rf /var/lib/apt/lists/*

# Download Kafka SQL connector JAR (TaskManager also needs it at runtime)
ADD https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.3.0-1.19/flink-sql-connector-kafka-3.3.0-1.19.jar /opt/flink/lib/
RUN chmod 644 /opt/flink/lib/flink-sql-connector-kafka-3.3.0-1.19.jar

# Copy the Flink job (build context = project root)
COPY flink/jobs/stock_tick_processor.py /opt/flink/jobs/stock_tick_processor.py

# Data + RPC ports
EXPOSE 6121 6122

# Uses base image ENTRYPOINT (/docker-entrypoint.sh) + ECS command ["taskmanager"]
