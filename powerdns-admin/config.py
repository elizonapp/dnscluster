### PowerDNS-Admin (PowerDNS-Admin-NG / fork)
import os

bind_address = '0.0.0.0'
port = 9191

SECRET_KEY = os.environ.get('SECRET_KEY')
SALT = os.environ.get('SALT')

# Dedicated DB for admin users/sessions (NOT the pdns DB!)
# In Compose: connect directly to HAProxy write backend (see docker-compose); do not use PgBouncer without a DB alias.
SQLA_DB_HOST = 'haproxy'
SQLA_DB_PORT = 5000
SQLA_DB_NAME = 'powerdnsadmin'
SQLA_DB_USER = 'pdns'
SQLA_DB_PASSWORD = os.environ.get('SQLA_DB_PASSWORD')

SQLALCHEMY_DATABASE_URI = (
    f"postgresql://{SQLA_DB_USER}:{SQLA_DB_PASSWORD}@{SQLA_DB_HOST}:{SQLA_DB_PORT}/{SQLA_DB_NAME}"
    "?sslmode=disable"
)
SQLALCHEMY_TRACK_MODIFICATIONS = False

# PowerDNS API: local via Docker network
PDNS_STATS_URL = 'http://powerdns:8081'
PDNS_API_KEY = os.environ.get('PDNS_API_KEY')
PDNS_VERSION = '4.9.0'

LOG_LEVEL = 'INFO'
LOG_FILE = ''

# Session/Cookie
SESSION_TYPE = 'sqlalchemy'
REMEMBER_COOKIE_DURATION = 2592000

# Security
SAML_ENABLED = False
OIDC_OAUTH_ENABLED = False
HSTS_ENABLED = True
