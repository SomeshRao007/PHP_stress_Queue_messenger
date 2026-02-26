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

# Enable Apache mod_rewrite and install Symfony VirtualHost config
RUN a2enmod rewrite
COPY docker/apache.conf /etc/apache2/sites-available/000-default.conf

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

RUN DATABASE_URL="postgresql://app:app_password@a434815-akamai-prod-3365827-default.g2a.akamaidb.net:28213/job_queue_demo?serverVersion=16&charset=utf8" \
    composer run-script post-install-cmd \
    && DATABASE_URL="postgresql://app:app_password@a434815-akamai-prod-3365827-default.g2a.akamaidb.net:28213/job_queue_demo?serverVersion=16&charset=utf8" \
    php bin/console cache:warmup

# ENV APP_ENV=prod
# RUN composer run-script post-install-cmd \
#     && php bin/console cache:warmup

# Set proper permissions
RUN chown -R www-data:www-data var/

EXPOSE 80
