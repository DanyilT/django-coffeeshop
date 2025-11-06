#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---- systemctl shim for Docker ----
if ! command -v systemctl >/dev/null 2>&1; then
  systemctl() {
    case "$*" in
      *"restart apache2"* | *"reload apache2"*)  apachectl -k restart || true ;;
      *"start apache2"*)      apachectl -k start || true ;;
      *"restart postgresql"*) pg_lsclusters | awk 'NR>1{print $1,$2}' | while read -r v n; do pg_ctlcluster "$v" "$n" restart || true; done ;;
      *"start postgresql"*)   pg_lsclusters | awk 'NR>1{print $1,$2}' | while read -r v n; do pg_ctlcluster "$v" "$n" start || true; done ;;
      *"restart mailcatcher"*) pkill -f mailcatcher || true; mailcatcher --smtp-ip 0.0.0.0 --http-ip 0.0.0.0 || true ;;
      *"start mailcatcher"* | *"enable mailcatcher"*) mailcatcher --smtp-ip 0.0.0.0 --http-ip 0.0.0.0 || true ;;
      *) true ;;
    esac
  }
fi

. /secrets/config.env

echo ". /secrets/config.env" >> /home/vagrant/.profile
echo ". /secrets/config.env" >> /home/vagrant/.bashrc

# Set hostname and fix resolution
hostname csthirdparty
echo "127.0.0.1 csthirdparty" >> /etc/hosts

# Start mailcatcher
echo "Starting Mailcatcher…"
systemctl start mailcatcher

# Install python packages from requirements.txt
echo "Installing Python requirements…"
pip3 install --no-cache-dir -r /vagrant/csthirdpartysite/requirements.txt

# ---- Start PostgreSQL cluster if needed ----
echo "Starting PostgreSQL if needed…"
if command -v pg_lsclusters >/dev/null 2>&1; then
  pg_lsclusters | awk 'NR>1{print $1,$2,$4}' | while read -r ver name state; do
    [ "$state" = "online" ] || pg_ctlcluster "$ver" "$name" start || true
  done
fi

# Install apache config
rm /etc/apache2/apache2.conf
rm /etc/apache2/envvars
cp /vagrant/apache2/apache2.conf /etc/apache2/
cp /vagrant/apache2/envvars /etc/apache2/

# Set up Postgres - dynamically detect version
echo "Configuring PostgreSQL…"
if command -v pg_lsclusters >/dev/null 2>&1; then
  pgvers=$(pg_lsclusters -h | awk '{print $1}' | head -1)
  echo "Detected PostgreSQL version: $pgvers"

  if [ -n "$pgvers" ] && [ -d "/etc/postgresql/${pgvers}/main" ]; then
    mv /etc/postgresql/${pgvers}/main/postgresql.conf /etc/postgresql/${pgvers}/main/postgresql.conf.orig 2>/dev/null || true
    mv /etc/postgresql/${pgvers}/main/pg_hba.conf /etc/postgresql/${pgvers}/main/pg_hba.conf.orig 2>/dev/null || true

    # Copy config files
    cp /vagrant/postgres/postgresql.conf /etc/postgresql/${pgvers}/main/postgresql.conf
    cp /vagrant/postgres/pg_hba.conf /etc/postgresql/${pgvers}/main/pg_hba.conf

    # Fix version-specific paths in postgresql.conf (replace 12 with actual version)
    sed -i "s|/postgresql/12/|/postgresql/${pgvers}/|g" /etc/postgresql/${pgvers}/main/postgresql.conf
    sed -i "s|/12-main\.pid|/${pgvers}-main.pid|g" /etc/postgresql/${pgvers}/main/postgresql.conf

    chown postgres.postgres /etc/postgresql/${pgvers}/main/postgresql.conf /etc/postgresql/${pgvers}/main/pg_hba.conf
    chmod 640 /etc/postgresql/${pgvers}/main/pg_hba.conf
    systemctl restart postgresql
  else
    echo "Warning: PostgreSQL version directory not found"
  fi
else
  echo "Warning: pg_lsclusters not found"
fi

# Install csthirdparty web app
ln -fs /vagrant/csthirdpartysite /var/www/

# Install web site
a2dissite 000-default.conf
cp /vagrant/apache2/000-default.conf /etc/apache2/sites-available/000-default.conf
a2ensite 000-default.conf
a2enmod rewrite
a2enmod headers
apachectl restart

# Set up database
cd /vagrant/csthirdpartysite
sudo -u postgres psql -c "CREATE DATABASE csthirdparty"
sudo -u postgres psql -c "CREATE USER $DBOWNER WITH PASSWORD '$DBOWNERPWD';"
sudo -u postgres psql -c "ALTER ROLE $DBOWNER SET client_encoding TO 'utf8'; ALTER ROLE $DBOWNER SET timezone TO 'UTC';"
sudo -u postgres psql -c "ALTER DATABASE csthirdparty OWNER TO $DBOWNER;"
python3 manage.py migrate
sudo -u vagrant bash "/var/www/csthirdpartysite/create_users.sh"
sudo -u vagrant bash "/var/www/csthirdpartysite/loaddata.sh"
sudo -u vagrant bash "/var/www/csthirdpartysite/collectstatic.sh"
systemctl restart apache2

# Add other users
adduser --disabled-password --gecos "" dbuser
usermod -a -G www-data vagrant

