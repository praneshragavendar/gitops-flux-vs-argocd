# Stage 1: build the WAR with Maven (no local Java/Maven install needed)
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q package

# Stage 2: run it on Tomcat; ROOT.war serves the app at "/"
FROM tomcat:9.0-jdk17-temurin
RUN rm -rf /usr/local/tomcat/webapps/*
COPY --from=build /src/target/MyMavenApp.war /usr/local/tomcat/webapps/ROOT.war
EXPOSE 8080
