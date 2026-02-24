FROM php:8.4-apache

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    libicu-dev \
    libzip-dev \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install PHP extensions
RUN docker-php-ext-install \
    pdo_pgsql \
    intl \
    zip \
    opcache

# Enable Apache mod_rewrite for Symfony routing
RUN a2enmod rewrite

# Set Apache DocumentRoot to Symfony's public/ directory
ENV APACHE_DOCUMENT_ROOT=/var/www/html/public
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf \
    && sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

# Allow .htaccess overrides (Symfony uses this for routing)
RUN sed -ri -e 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf

# Install Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

# Copy composer files first for layer caching
COPY composer.json composer.lock symfony.lock ./

# Install dependencies (no dev, optimized autoloader)
RUN composer install --no-dev --optimize-autoloader --no-scripts --no-interaction

# Copy application source
COPY . .

# Run Symfony post-install scripts and warm up cache

# RUN DATABASE_URL="postgresql://app:app_password@127.0.0.1:5432/job_queue_demo?serverVersion=16&charset=utf8" \
#     composer run-script post-install-cmd \
#     && DATABASE_URL="postgresql://app:app_password@127.0.0.1:5432/job_queue_demo?serverVersion=16&charset=utf8" \
#     php bin/console cache:warmup

ENV APP_ENV=prod
RUN composer run-script post-install-cmd \
    && php bin/console cache:warmup

# Set proper permissions
RUN chown -R www-data:www-data var/

EXPOSE 80
