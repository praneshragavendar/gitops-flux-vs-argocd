<%@ page contentType="text/html; charset=UTF-8" %>
<html>
<head><title>Java app on Kubernetes</title></head>
<body>
<h2>Hello from the Java app!</h2>
<p>A Maven-built WAR running on Tomcat, deployed to Kubernetes by GitOps.</p>
<p>Served by pod: <%= System.getenv("HOSTNAME") %></p>
</body>
</html>
