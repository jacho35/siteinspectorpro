# SnagTrack Pro — Docker Installation Guide

## Architecture Overview

```
┌──────────────────────────────────────────────────────┐
│                    Your Server                        │
│                                                       │
│  ┌─────────────────┐      ┌──────────────────────┐   │
│  │  Nginx (Port 80) │      │  CouchDB (Port 5984) │   │
│  │  ─────────────── │      │  ────────────────────│   │
│  │  Serves HTML/JS  │◄────►│  Sync database       │   │
│  │  PWA + SSL       │      │  Conflict resolution │   │
│  └────────┬─────────┘      └──────────┬───────────┘   │
│           │                           │               │
└───────────┼───────────────────────────┼───────────────┘
            │                           │
     ┌──────┴──────┐            ┌───────┴──────┐
     │   Browser    │            │   PouchDB    │
     │  IndexedDB   │◄──────────►│   (Sync)    │
     │  (Offline)   │            │             │
     └─────────────┘            └──────────────┘
```

---

## Prerequisites

- A Linux server (Ubuntu 20.04+, Debian 11+, or similar)
- SSH access with sudo privileges
- A domain name (optional, but required for HTTPS)
- Minimum 1GB RAM, 10GB disk

---

## Step-by-Step Installation

### Step 1 — Install Docker

If Docker is not already installed on your server:

```bash
# SSH into your server
ssh user@your-server-ip

# Install Docker using the official script
curl -fsSL https://get.docker.com | sh

# Add your user to the docker group (avoids needing sudo)
sudo usermod -aG docker $USER

# IMPORTANT: Log out and back in for group change to take effect
exit
ssh user@your-server-ip

# Verify Docker is running
docker --version
docker compose version
```

### Step 2 — Upload Project Files

Upload the project folder to your server. Choose one method:

**Option A — SCP (from your local machine):**
```bash
scp -r snag-tracker-docker/ user@your-server-ip:~/snagtrack/
```

**Option B — Git (if you push to a repo):**
```bash
git clone https://github.com/youruser/snagtrack.git ~/snagtrack
```

**Option C — Create directly on server:**
```bash
mkdir -p ~/snagtrack/app
cd ~/snagtrack
# Then create each file (Dockerfile, docker-compose.yml, etc.)
```

### Step 3 — Configure Environment

```bash
cd ~/snagtrack

# Create your .env file from the template
cp .env.example .env

# Edit with your preferred editor
nano .env
```

**Change these values in `.env`:**
```
COUCHDB_USER=admin
COUCHDB_PASSWORD=your_strong_password_here
DOMAIN=snagtrack.yourdomain.com      # optional, for SSL
SSL_EMAIL=you@yourdomain.com          # optional, for SSL
```

### Step 4 — Run the Setup Script (Recommended)

The automated script handles everything:

```bash
chmod +x setup.sh
./setup.sh
```

This will:
1. Verify Docker is installed and running
2. Build the Docker image
3. Start all containers
4. Configure CouchDB with CORS for browser sync
5. Create all required databases
6. Print access URLs

**If you prefer to do it manually, see Step 4 (Manual) below.**

### Step 4 (Manual) — Build and Start Containers

```bash
cd ~/snagtrack

# Build the Docker image
docker compose build

# Start all services in the background
docker compose up -d

# Verify containers are running
docker compose ps

# You should see:
#   snagtrack-web      running    0.0.0.0:80->80/tcp
#   snagtrack-couchdb  running    0.0.0.0:5984->5984/tcp
```

**Initialize CouchDB manually:**
```bash
# Set your credentials (match your .env)
COUCH_URL="http://admin:your_password@localhost:5984"

# Enable CORS (required for browser-based PouchDB sync)
curl -X PUT "$COUCH_URL/_node/_local/_config/httpd/enable_cors" -d '"true"'
curl -X PUT "$COUCH_URL/_node/_local/_config/cors/origins" -d '"*"'
curl -X PUT "$COUCH_URL/_node/_local/_config/cors/methods" -d '"GET, PUT, POST, HEAD, DELETE"'
curl -X PUT "$COUCH_URL/_node/_local/_config/cors/headers" -d '"accept, authorization, content-type, origin, referer"'

# Create databases
curl -X PUT "$COUCH_URL/snagtrack_projects"
curl -X PUT "$COUCH_URL/snagtrack_locations"
curl -X PUT "$COUCH_URL/snagtrack_snags"
curl -X PUT "$COUCH_URL/snagtrack_photos"
curl -X PUT "$COUCH_URL/snagtrack_comments"
```

### Step 5 — Verify Installation

```bash
# Check container status
docker compose ps

# Check web app health
curl http://localhost/health
# Expected: {"status":"ok"}

# Check CouchDB health
curl http://localhost:5984/_up
# Expected: {"status":"ok"}

# Check logs if something is wrong
docker compose logs -f
```

**Open in your browser:**
- Web app: `http://your-server-ip`
- CouchDB admin panel: `http://your-server-ip:5984/_utils`

### Step 6 — Install on Mobile Phone

1. Open `http://your-server-ip` in Chrome (Android) or Safari (iOS)
2. **Android:** Tap the three-dot menu → "Add to Home Screen"
3. **iOS:** Tap the Share button → "Add to Home Screen"
4. The app will now appear as an icon on your phone
5. It works offline — data syncs when you reconnect

---

## Setting Up HTTPS (Production)

HTTPS is **required** for service workers on non-localhost domains.

### Option A — Let's Encrypt (Free, Automated)

**1. Point your domain to your server:**
```
Type: A
Name: snagtrack (or @ for root)
Value: your-server-ip
TTL: 300
```

**2. Update your `.env`:**
```
DOMAIN=snagtrack.yourdomain.com
SSL_EMAIL=you@yourdomain.com
```

**3. Create the SSL nginx config:**

Replace your `nginx.conf` with:

```nginx
# HTTP → HTTPS redirect
server {
    listen 80;
    server_name snagtrack.yourdomain.com;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name snagtrack.yourdomain.com;

    ssl_certificate     /etc/nginx/ssl/live/snagtrack.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/live/snagtrack.yourdomain.com/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /usr/share/nginx/html;
    index index.html;

    # ... (copy all location blocks from original nginx.conf) ...

    location / {
        try_files $uri $uri/ /index.html;
    }

    location = /sw.js {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Service-Worker-Allowed "/";
    }
}
```

**4. Get the certificate:**
```bash
# First run — get the certificate
docker compose --profile ssl up certbot

# Rebuild nginx with SSL config
docker compose build --no-cache snagtrack
docker compose up -d snagtrack
```

**5. Auto-renew (add to crontab):**
```bash
crontab -e
# Add this line:
0 3 * * 1 cd ~/snagtrack && docker compose --profile ssl run --rm certbot renew && docker compose restart snagtrack
```

### Option B — Cloudflare Proxy (Easiest)

1. Add your domain to Cloudflare (free plan works)
2. Set DNS A record pointing to your server
3. Enable "Proxied" (orange cloud) on the DNS record
4. In SSL/TLS settings, set mode to "Full"
5. Cloudflare handles HTTPS automatically — no changes to your server needed

---

## Daily Operations

### Common Commands

```bash
# View live logs
docker compose logs -f

# View logs for specific service
docker compose logs -f snagtrack
docker compose logs -f couchdb

# Restart everything
docker compose restart

# Stop everything
docker compose down

# Stop and remove all data (DANGER)
docker compose down -v
```

### Updating the App

When you have a new version of the app files:

```bash
cd ~/snagtrack

# Replace files in app/ directory with new versions
# Then rebuild and restart:
docker compose build --no-cache
docker compose up -d
```

### Backup

```bash
# Backup CouchDB data
docker compose exec couchdb tar czf - /opt/couchdb/data > couchdb-backup-$(date +%Y%m%d).tar.gz

# Backup everything (config + data)
tar czf snagtrack-full-backup-$(date +%Y%m%d).tar.gz \
    ~/snagtrack/ \
    --exclude=node_modules

# Restore CouchDB backup
docker compose down
docker compose up -d couchdb
docker cp couchdb-backup.tar.gz snagtrack-couchdb:/tmp/
docker compose exec couchdb bash -c "cd / && tar xzf /tmp/couchdb-backup.tar.gz"
docker compose restart couchdb
```

### Monitoring

```bash
# Check disk usage
docker system df

# Check container resource usage
docker stats

# Clean up old images
docker image prune -f
```

---

## Firewall Configuration

If your server has a firewall (recommended), open these ports:

```bash
# UFW (Ubuntu)
sudo ufw allow 80/tcp     # HTTP
sudo ufw allow 443/tcp    # HTTPS
sudo ufw allow 22/tcp     # SSH
# Do NOT expose port 5984 publicly unless you need external CouchDB access
# sudo ufw allow 5984/tcp   # CouchDB (optional, LAN only recommended)
sudo ufw enable

# firewalld (CentOS/RHEL)
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

**Security note:** CouchDB port 5984 should ideally NOT be exposed to the public internet. The Nginx container communicates with CouchDB internally via Docker networking. If you need external sync, put CouchDB behind Nginx as a reverse proxy with authentication.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Connection refused" on port 80 | Check: `docker compose ps` — is snagtrack-web running? Check firewall. |
| CouchDB won't start | Check logs: `docker compose logs couchdb`. Verify .env credentials. |
| Service worker not registering | HTTPS is required for SW on non-localhost. Set up SSL first. |
| App won't install on phone | Needs HTTPS + valid manifest.json. Check browser DevTools → Application tab. |
| Photos not saving | Check browser storage quota. IndexedDB typically allows 50%+ of disk. |
| "CORS error" in console | Re-run CouchDB CORS setup commands from Step 4. |
| Containers restart in loop | Check: `docker compose logs`. Usually a config error or port conflict. |
| Port 80 already in use | Stop other web servers: `sudo systemctl stop apache2` or `sudo systemctl stop nginx` |

---

## File Structure

```
snagtrack/
├── Dockerfile              # Builds the nginx web server image
├── docker-compose.yml      # Defines all services
├── nginx.conf              # Web server configuration
├── setup.sh                # Automated setup script
├── .env.example            # Environment template
├── .env                    # Your configuration (git-ignored)
├── .dockerignore           # Files excluded from Docker build
├── README.md               # This file
└── app/                    # Application files
    ├── index.html          # Main application
    ├── sw.js               # Service worker (offline support)
    └── manifest.json       # PWA manifest (mobile install)
```
