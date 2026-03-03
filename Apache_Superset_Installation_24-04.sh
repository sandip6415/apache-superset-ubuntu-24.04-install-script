#!/bin/bash

set -e

echo "========================================"
echo "Apache Superset Production Installer"
echo "Supports Ubuntu 20.04 / 22.04 / 24.04"
echo "========================================"

APP_DIR="/app/superset"
VENV_DIR="$APP_DIR/superset_env"
CONFIG_FILE="$APP_DIR/superset_config.py"

# Detect Ubuntu version
UBUNTU_VERSION=$(lsb_release -rs)
echo "Detected Ubuntu version: $UBUNTU_VERSION"

echo "Updating system..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo "Installing base dependencies..."

sudo apt install -y \
    build-essential \
    curl \
    wget \
    git \
    pkg-config \
    nginx \
    redis-server \
    postgresql \
    postgresql-contrib \
    libpq-dev \
    libsasl2-dev \
    libldap2-dev \
    libssl-dev \
    libffi-dev \
    libjpeg-dev \
    zlib1g-dev \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    unixodbc \
    unixodbc-dev \
        libkrb5-dev \
    default-libmysqlclient-dev


if systemctl list-unit-files | grep -q redis-server; then
    sudo systemctl enable redis-server --now
fi

# Create the directory structure
echo "Creating /app directory..."
sudo mkdir -p /app
sudo chown -R $(whoami):$(whoami) /app
cd /app

echo "Setting up virtual environment..."
mkdir -p superset
cd superset
python3 -m venv superset_env
source superset_env/bin/activate

# Upgrade pip, wheel and setuptools
echo "Upgrading pip, setuptools, and wheel..."
pip install --upgrade pip setuptools wheel

# Install Apache Superset and required packages
echo "Installing Apache Superset..."
pip install --no-cache-dir --upgrade "apache-superset[postgres,redis]"

# Create the superset_config.py file with the desired content
echo "Creating superset_config.py file..."
cat <<EOL > /app/superset/superset_config.py
#Superset specific config
ROW_LIMIT = 5000

# Flask App Builder configuration
# Your App secret key will be used for securely signing the session cookie
# and encrypting sensitive information on the database
# Make sure you are changing this key for your deployment with a strong key.
# Alternatively you can set it with \`SUPERSET_SECRET_KEY\` environment variable.
# You MUST set this for production environments or the server will not refuse
# to start and you will see an error in the logs accordingly.
SECRET_KEY = 'XmrMVVns/EcA1jfi2+Baxuv7zXS0r0SLWV8Ws/KN0Jb3OF5Rs1y03oH/'

# The SQLAlchemy connection string to your database backend
# This connection defines the path to the database that stores your
# superset metadata (slices, connections, tables, dashboards, ...).
# Note that the connection information to connect to the datasources
# you want to explore are managed directly in the web UI
# The check_same_thread=false property ensures the sqlite client does not attempt
# to enforce single-threaded access, which may be problematic in some edge cases
SQLALCHEMY_DATABASE_URI = 'sqlite:////app/superset/superset.db?check_same_thread=false'

TALISMAN_ENABLED = False
WTF_CSRF_ENABLED = False
ENABLE_STATS = False

# Set this API key to enable Mapbox visualizations
MAPBOX_API_KEY = ''
EOL

# Set the Superset config path
export SUPERSET_CONFIG_PATH=/app/superset/superset_config.py

# Set the FLASK_APP environment variable
export FLASK_APP=superset

# Upgrade the database schema
echo "Upgrading the database..."
superset db upgrade

# Create the admin user (this will ask for username, password, and email)
echo "Creating admin user...Please provide the STRONG Password"
superset fab create-admin

# Initialize Superset
echo "Initializing Superset..."
superset init

# Step 1: Create the run_superset.sh script to start Superset with Gunicorn
echo "Creating run_superset.sh script..."
cat <<EOL > /app/superset/run_superset.sh
#!/bin/bash
export SUPERSET_CONFIG_PATH=/app/superset/superset_config.py
. /app/superset/superset_env/bin/activate

WORKERS=\$(($(nproc) * 2 + 1))

gunicorn \
      -w \$WORKERS \
      -k gevent \
      --timeout 120 \
      -b 0.0.0.0:8088 \
      --limit-request-line 0 \
      --limit-request-field_size 0 \
      "superset.app:create_app()"
EOL

# Make the run_superset.sh script executable
chmod +x /app/superset/run_superset.sh

# Step 2: Create the systemd service file for Superset
echo "Creating superset.service systemd service..."
sudo bash -c 'cat <<EOL > /etc/systemd/system/superset.service
[Unit]
Description=Apache Superset Webserver Daemon
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/app/superset
Environment=SUPERSET_HOME=/app/superset
Environment=SUPERSET_CONFIG_PATH=/app/superset/superset_config.py
ExecStart=/app/superset/run_superset.sh
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL'

# Install Microsoft ODBC driver and required Python packages for MS SQL Server
echo "Installing Microsoft ODBC Driver and Python dependencies for MS SQL..."

UBUNTU_VERSION=$(lsb_release -rs)

# Fallback for Ubuntu 24.04
if [[ "$UBUNTU_VERSION" == "22.04" ]]; then
    MS_REPO_VERSION="22.04"
else
    MS_REPO_VERSION="$UBUNTU_VERSION"
fi
sudo mkdir -p /etc/apt/keyrings

sudo rm -f /etc/apt/sources.list.d/mssql-release.list
# Add Microsoft GPG key properly
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null

# Add repository with signed-by
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/$MS_REPO_VERSION/prod $(lsb_release -cs) main" \
| sudo tee /etc/apt/sources.list.d/mssql-release.list
sudo apt update
sudo ACCEPT_EULA=Y apt install -y msodbcsql18 unixodbc-dev
pip install pyodbc sqlalchemy

# Reload the systemd configuration
echo "Reloading systemd..."
sudo systemctl daemon-reload

# Enable and start the Superset service
echo "Enabling and starting Superset service..."
sudo systemctl enable superset.service
sudo systemctl start superset.service

#Allow 8088 Port
if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow 8088/tcp
fi


# Check the status of the Superset service
echo "Checking Superset service status..."
sudo systemctl status superset.service

#=============================================================================
#IMP Note: Delete & recreated Public Role from Gamaa
#In Public Role give .dbo schema access to publish dashboard
#=============================================================================
