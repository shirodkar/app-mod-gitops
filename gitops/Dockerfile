# Build stage
FROM registry.access.redhat.com/ubi9/openjdk-21:latest AS builder
WORKDIR /build
COPY . .
RUN mvn package -DskipTests

# Runtime stage
FROM registry.access.redhat.com/ubi9/openjdk-21-runtime:latest
WORKDIR /deployments
COPY --from=builder /build/target/*.jar app.jar
EXPOSE 8080
ENV JAVA_OPTS=""
CMD ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
