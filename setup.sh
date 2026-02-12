#!/usr/bin/env bash
# ============================================================
# Site Inspector Pro — Setup Script
# ============================================================
set -euo pipefail

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()  { echo -e "  ${RED}✖${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }
header() { echo ""; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}  $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Step 1: Prerequisites ───────────────────────────────────
header "Step 1 — Checking Prerequisites"

command -v docker &>/dev/null && ok "Docker found: $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)" || { err "Docker not installed. Run: curl -fsSL https://get.docker.com | sh"; exit 1; }

if docker compose version &>/dev/null; then
    ok "Docker Compose found"
    COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    ok "Docker Compose (standalone) found"
    COMPOSE="docker-compose"
else
    err "Docker Compose not installed. Run: sudo apt install docker-compose-plugin"; exit 1
fi

docker info &>/dev/null && ok "Docker daemon running" || { err "Docker not running. Start: sudo systemctl start docker"; exit 1; }

# ── Step 2: Environment ─────────────────────────────────────
header "Step 2 — Environment Configuration"

if [ ! -f .env ]; then
    cp .env.example .env 2>/dev/null || echo -e "COUCHDB_USER=admin\nCOUCHDB_PASSWORD=changeme" > .env
    warn ".env created with defaults — edit the password!"
    echo ""
    echo -e "    ${YELLOW}IMPORTANT: Change COUCHDB_PASSWORD in .env${NC}"
    echo "      nano .env"
    echo ""
    read -p "    Continue with defaults? (y/N) " -n 1 -r; echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && { info "Edit .env then re-run."; exit 0; }
else
    ok ".env exists"
fi

set -a; source .env; set +a

# ── Step 3: Build ────────────────────────────────────────────
header "Step 3 — Building Docker Image"

info "Building..."
$COMPOSE build --no-cache snagtrack
ok "Image built"

# ── Step 4: Start ────────────────────────────────────────────
header "Step 4 — Starting Containers"

$COMPOSE up -d
ok "Containers started"

info "Waiting for CouchDB to be healthy..."
for i in {1..20}; do
    if curl -sf http://localhost:5984/_up &>/dev/null; then ok "CouchDB healthy"; break; fi
    [ $i -eq 20 ] && warn "CouchDB still starting... continuing anyway"
    sleep 2
done

# ── Step 5: Initialize CouchDB ──────────────────────────────
header "Step 5 — Initializing CouchDB"

COUCH="http://${COUCHDB_USER:-admin}:${COUCHDB_PASSWORD:-changeme}@localhost:5984"

# Enable CORS
info "Configuring CORS..."
for CFG in \
    "httpd/enable_cors:true" \
    "cors/origins:*" \
    'cors/methods:GET, PUT, POST, HEAD, DELETE' \
    'cors/headers:accept, authorization, content-type, origin, referer' \
    'cors/credentials:true'; do
    KEY="${CFG%%:*}"; VAL="${CFG#*:}"
    curl -sf -X PUT "$COUCH/_node/_local/_config/$KEY" -d "\"$VAL\"" -H "Content-Type: application/json" >/dev/null 2>&1 || true
done
ok "CORS configured"

# Increase document and request size limits for photo sync
info "Configuring size limits for photo sync..."
curl -sf -X PUT "$COUCH/_node/_local/_config/couchdb/max_document_size" -d '"67108864"' -H "Content-Type: application/json" >/dev/null 2>&1 || true
curl -sf -X PUT "$COUCH/_node/_local/_config/httpd/max_http_request_size" -d '"67108864"' -H "Content-Type: application/json" >/dev/null 2>&1 || true
ok "Max document size: 64MB, Max HTTP request: 64MB"

# Ensure _users and _replicator system databases exist
info "Creating system databases..."
for DB in _users _replicator _global_changes; do
    curl -sf -X PUT "$COUCH/$DB" >/dev/null 2>&1 || true
done
ok "System databases ready"

# Allow admin to create user accounts (the app's register function uses admin creds)
# Also allow users to read their own _session
info "Configuring authentication..."
curl -sf -X PUT "$COUCH/_node/_local/_config/chttpd_auth/allow_persistent_cookies" -d '"true"' -H "Content-Type: application/json" >/dev/null 2>&1 || true
ok "Authentication configured"

# Helper function: create a user and their per-user databases
create_user() {
    local USERNAME="$1"
    local PASSWORD="$2"
    info "Creating user: $USERNAME"

    # Create user document
    local USERDOC="{\"_id\":\"org.couchdb.user:${USERNAME}\",\"name\":\"${USERNAME}\",\"password\":\"${PASSWORD}\",\"roles\":[],\"type\":\"user\"}"
    local RESULT=$(curl -sf -X PUT "$COUCH/_users/org.couchdb.user:${USERNAME}" -d "$USERDOC" -H "Content-Type: application/json" 2>&1 || true)
    if echo "$RESULT" | grep -q '"ok"'; then ok "User created: $USERNAME"
    elif echo "$RESULT" | grep -q 'conflict'; then ok "User exists: $USERNAME"
    else warn "User $USERNAME: $RESULT"; fi

    # Convert username to hex for database names
    local HEX=$(printf '%s' "$USERNAME" | xxd -p | tr -d '\n')

    # Create per-user databases
    for SUFFIX in projects locations snags photos comments settings; do
        local DBNAME="userdb_${HEX}_${SUFFIX}"
        local DBRESULT=$(curl -sf -X PUT "$COUCH/$DBNAME" 2>&1 || true)
        if echo "$DBRESULT" | grep -q '"ok"'; then ok "  Created: $DBNAME"
        elif echo "$DBRESULT" | grep -q 'file_exists'; then ok "  Exists:  $DBNAME"
        else warn "  $DBNAME: $DBRESULT"; fi

        # Set security: only this user can access their databases
        local SECDOC="{\"admins\":{\"names\":[\"${USERNAME}\"],\"roles\":[]},\"members\":{\"names\":[\"${USERNAME}\"],\"roles\":[]}}"
        curl -sf -X PUT "$COUCH/$DBNAME/_security" -d "$SECDOC" -H "Content-Type: application/json" >/dev/null 2>&1 || true
    done
    ok "Databases created for $USERNAME"
}

# Create a default user if requested
echo ""
echo -e "  ${BOLD}Create a user account?${NC}"
read -p "    Username (or press Enter to skip): " NEW_USER
if [ -n "$NEW_USER" ]; then
    read -s -p "    Password: " NEW_PASS; echo ""
    create_user "$NEW_USER" "$NEW_PASS"
fi

# ── Step 6: Verify ──────────────────────────────────────────
header "Step 6 — Verification"

echo ""
$COMPOSE ps
echo ""

# Test the proxy path
info "Testing nginx → CouchDB proxy..."
if curl -sf http://localhost:8082/db/_up | grep -q '"ok"'; then
    ok "Proxy /db/ → CouchDB working!"
else
    warn "Proxy test failed. Check nginx.conf has the /db/ location block."
fi

# ── Done ─────────────────────────────────────────────────────
header "Setup Complete!"

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "your-server-ip")

echo ""
echo -e "  ${GREEN}${BOLD}Site Inspector Pro is running!${NC}"
echo ""
echo -e "  ${BOLD}Web App:${NC}  ${CYAN}http://${SERVER_IP}:8082${NC}"
echo ""
echo -e "  ${BOLD}How to use:${NC}"
echo "    1. Open the app URL on any device"
echo "    2. Create an account or sign in"
echo "    3. Each user gets their own projects, snags, and settings"
echo "    4. Data syncs automatically when online"
echo "    5. Works offline — syncs when connection returns"
echo ""
echo -e "  ${BOLD}Admin credentials:${NC} ${COUCHDB_USER:-admin} / ${COUCHDB_PASSWORD:-changeme}"
echo -e "  ${BOLD}CouchDB Dashboard:${NC} ${CYAN}http://${SERVER_IP}:8082/db/_utils${NC}"
echo ""
echo -e "  ${BOLD}Add users from command line:${NC}"
echo "    ./setup.sh  (follow prompts)"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "    Logs:     docker compose logs -f"
echo "    Stop:     docker compose down"
echo "    Restart:  docker compose restart"
echo "    Update:   docker compose build --no-cache && docker compose up -d"
echo "    Backup:   docker compose exec couchdb tar czf - /opt/couchdb/data > backup.tar.gz"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
