# Static Mom & Pop Cafe site served by nginx (small, non-root-friendly base image)
FROM nginx:1.27-alpine

COPY index.html /usr/share/nginx/html/
COPY css/ /usr/share/nginx/html/css/
COPY images/ /usr/share/nginx/html/images/

EXPOSE 80
