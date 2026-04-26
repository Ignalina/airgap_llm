#!/usr/bin/env bash
# Bygg Iceberg 1.11.0-SNAPSHOT från källa på T14s (offline)
# Kräver: Java 17+, nätverksåtkomst ELLER Gradle deps cache
set -euo pipefail

BASE=/media/rickard/T9/airgap
ICEBERG_DIR=$BASE/git/iceberg
SPARK_SCALA="4.1_2.13"   # matchar Spark 4.1.1

cd $ICEBERG_DIR

echo "Bygger Iceberg Spark runtime JAR för Spark ${SPARK_SCALA}..."
./gradlew :iceberg-spark:iceberg-spark-runtime-${SPARK_SCALA}:jar \
    -x test \
    -x javadoc \
    --no-daemon \
    2>&1 | tail -20

JAR=$(find . -name "iceberg-spark-runtime-${SPARK_SCALA}-*.jar" -not -path "*/classes/*" | head -1)
echo "JAR byggd: $JAR"
cp "$JAR" $BASE/java/
echo "Kopierad till $BASE/java/"
