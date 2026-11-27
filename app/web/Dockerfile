FROM php:7.4-apache

# mysqli is the only PHP extension the app needs
RUN docker-php-ext-install mysqli

COPY . /var/www/html/

EXPOSE 80
