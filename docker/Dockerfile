# ==========================================
# docker/Dockerfile - Production-ready container
# ==========================================
FROM python:3.11-slim as base

# Metadata for container identification and documentation
LABEL maintainer="your.email@domain.com" \
    version="1.0.0" \
    description="TikSimPro - Automated TikTok Content Generator for Kubernetes" \
    repository="https://github.com/YOUR_USERNAME/tiksimpro-kubernetes"

# Environment variables for Python and application configuration
# PYTHONPATH: Ensures Python can find our application modules
# PYTHONUNBUFFERED: Forces Python to output directly (important for Docker logs)
# PIP_NO_CACHE_DIR: Reduces image size by not caching pip downloads
ENV PYTHONPATH=/app \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DISPLAY=:99

# Install system dependencies required for video processing and web automation
# We group these installations and clean up in the same layer to reduce image size
RUN apt-get update && apt-get install -y \
    # Video processing tools
    ffmpeg \
    # Web automation tools for Chrome
    wget gnupg curl \
    # Virtual display for headless browser automation
    xvfb \
    # Fonts and GUI libraries for browser rendering
    fonts-liberation libappindicator3-1 libasound2 libatk-bridge2.0-0 \
    libnspr4 libnss3 lsb-release xdg-utils libxss1 libgconf-2-4 \
    libxrandr2 libpangocairo-1.0-0 libatk1.0-0 libcairo-gobject2 \
    libgtk-3-0 libgdk-pixbuf2.0-0 \
    # Install Google Chrome for social media automation
    && wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | apt-key add - \
    && echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" >> /etc/apt/sources.list.d/google.list \
    && apt-get update && apt-get install -y google-chrome-stable \
    # Clean up to reduce image size - this is a Docker best practice
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Create a non-root user for security best practices
# Running containers as root is a security risk in production environments
RUN groupadd -r tiksimpro && useradd -r -g tiksimpro tiksimpro

# Set the working directory where our application will live
WORKDIR /app

# Copy requirements first for better Docker layer caching
# This means if we change code but not dependencies, Docker can reuse this layer
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the entire application codebase
# Using --chown ensures proper ownership for our non-root user
COPY --chown=tiksimpro:tiksimpro . .

# Create necessary directories for application data
# These directories will store videos, logs, and temporary files
RUN mkdir -p /app/{data,logs,videos,temp,music,trend_cache} \
    && chown -R tiksimpro:tiksimpro /app

# Create a health check script that Kubernetes can use to verify container health
COPY docker/scripts/health-check.sh /usr/local/bin/health-check.sh
RUN chmod +x /usr/local/bin/health-check.sh

# Switch to non-root user for security
USER tiksimpro

# Health check for Kubernetes liveness and readiness probes
# This tells Kubernetes whether the container is healthy and ready to receive traffic
HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=3 \
    CMD /usr/local/bin/health-check.sh

# Expose port for metrics and monitoring (Prometheus can scrape this)
EXPOSE 8080

# Default command to run the application
# This can be overridden in Kubernetes deployments
ENTRYPOINT ["python"]
CMD ["main.py"]