#!/usr/bin/env bash
# QSL Swarm Dashboard — Status Collector
# Runs every 5min via cron, writes data/status.json, git push for Vercel
set -euo pipefail

DASHBOARD_DIR="$HOME/qsl-dashboard"
OUTPUT="$DASHBOARD_DIR/public/data/status.json"
HOSTINGER="69.62.69.140"
HOSTINGER_TIMEOUT=10
COLLECT_START=$(date +%s)

# --- Helpers ---
json_escape() { python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$1" 2>/dev/null || echo '""'; }

# --- CABINET: Agent Status ---
# CrawDaddy seller
SELLER_PID=$(pgrep -f "seller.ts" 2>/dev/null | head -1 || true)
if [ -n "$SELLER_PID" ]; then
  SELLER_STATUS="running"
  SELLER_RAM=$(ps -o rss= -p "$SELLER_PID" 2>/dev/null | awk '{printf "%.0fM", $1/1024}' || echo "—")
  SELLER_UPTIME=$(ps -o etime= -p "$SELLER_PID" 2>/dev/null | xargs || echo "—")
else
  SELLER_STATUS="stopped"
  SELLER_RAM="—"
  SELLER_UPTIME="—"
fi

# Bastion — intentionally disabled, pending ContentBot + revenue milestone
BASTION_STATUS="disabled"
BASTION_RAM="—"
BASTION_UPTIME="—"

# OpenClaw Gateway
GW_PID=$(pgrep -f "openclaw" 2>/dev/null | head -1 || true)
if [ -n "$GW_PID" ]; then
  GW_STATUS="running"
  GW_RAM=$(ps -o rss= -p "$GW_PID" 2>/dev/null | awk '{printf "%.0fM", $1/1024}' || echo "—")
  GW_UPTIME=$(ps -o etime= -p "$GW_PID" 2>/dev/null | xargs || echo "—")
else
  GW_STATUS="stopped"
  GW_RAM="—"
  GW_UPTIME="—"
fi

# ResearchBot
RB_ACTIVE=$(systemctl is-active researchbot.service 2>/dev/null || echo "inactive")
if [ "$RB_ACTIVE" = "active" ]; then
  RB_STATUS="running"
  RB_PID=$(systemctl show researchbot.service --property=MainPID --value 2>/dev/null || true)
  if [ -n "$RB_PID" ] && [ "$RB_PID" != "0" ]; then
    RB_RAM=$(ps -o rss= -p "$RB_PID" 2>/dev/null | awk '{printf "%.0fM", $1/1024}' || echo "—")
    RB_UPTIME=$(ps -o etime= -p "$RB_PID" 2>/dev/null | xargs || echo "—")
  else
    RB_RAM="—"
    RB_UPTIME="—"
  fi
else
  RB_STATUS="stopped"
  RB_RAM="—"
  RB_UPTIME="—"
fi

# SN61 Miner (Hostinger — remote check)
MINER_STATUS="unknown"
MINER_RAM="—"
MINER_RUNNING=false
HOSTINGER_REACHABLE=false
if timeout "$HOSTINGER_TIMEOUT" bash -c "echo >/dev/tcp/$HOSTINGER/22" 2>/dev/null; then
  HOSTINGER_REACHABLE=true
  MINER_CHECK=$(sshpass -p 'Quantum#4728' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@"$HOSTINGER" \
    'docker ps --filter name=miner-agent-miner-1 --format "{{.Status}}" 2>/dev/null' 2>/dev/null || echo "")
  if echo "$MINER_CHECK" | grep -qi "up"; then
    MINER_STATUS="running"
    MINER_RUNNING=true
    MINER_RAM=$(sshpass -p 'Quantum#4728' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@"$HOSTINGER" \
      'docker stats --no-stream --format "{{.MemUsage}}" miner-agent-miner-1 2>/dev/null' 2>/dev/null | awk '{print $1}' || echo "—")
  else
    MINER_STATUS="stopped"
  fi
fi

# --- TREASURY ---
CONWAY_CREDITS="—"
CONWAY_TIER="—"
if [ -f "$HOME/.automaton/state.db" ]; then
  CREDIT_JSON=$(sqlite3 "$HOME/.automaton/state.db" "SELECT value FROM kv WHERE key='last_credit_check' LIMIT 1" 2>/dev/null || echo "")
  if [ -n "$CREDIT_JSON" ]; then
    CONWAY_CREDITS=$(echo "$CREDIT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'\${d.get(\"credits\",0)/100:.2f}')" 2>/dev/null || echo "—")
    CONWAY_TIER=$(echo "$CREDIT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tier','—'))" 2>/dev/null || echo "—")
  fi
fi

# CrawDaddy wallet — USDC balance on Base via RPC (no API key needed)
# USDC contract: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
# CrawDaddy address: 0x25B50fEd69175e474F9702C0613413F8323809a8
CRAWDADDY_BALANCE="—"
CRAWDADDY_RESP=$(curl -sf --max-time 10 -X POST "https://mainnet.base.org" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913","data":"0x70a0823100000000000000000000000025B50fEd69175e474F9702C0613413F8323809a8"},"latest"],"id":1}' 2>/dev/null || echo "")
if [ -n "$CRAWDADDY_RESP" ]; then
  CRAWDADDY_BALANCE=$(echo "$CRAWDADDY_RESP" | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('result','0x0')
balance=int(r,16)/1e6
print(f'\${balance:.2f}')
" 2>/dev/null || echo "—")
fi

# Bastion wallet — ETH balance on Base via RPC
# Bastion address: 0xEEF60d4E36EdcfE75b07ffA8a492212660452DD4
BASTION_BALANCE="—"
BASTION_RESP=$(curl -sf --max-time 10 -X POST "https://mainnet.base.org" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0xEEF60d4E36EdcfE75b07ffA8a492212660452DD4","latest"],"id":1}' 2>/dev/null || echo "")
if [ -n "$BASTION_RESP" ]; then
  BASTION_BALANCE=$(echo "$BASTION_RESP" | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('result','0x0')
eth=int(r,16)/1e18
if eth > 0.001: print(f'{eth:.4f} ETH')
else: print('0 ETH')
" 2>/dev/null || echo "—")
fi

# --- INTEL FEED (latest ResearchBot items from DB) ---
INTEL_JSON="[]"
RB_DB="$HOME/qsl-swarm/CABINET/researchbot/data/researchbot.db"
if [ -f "$RB_DB" ]; then
  INTEL_JSON=$(python3 -c "
import sqlite3, json
conn = sqlite3.connect('$RB_DB')
rows = conn.execute('''
  SELECT i.title, s.name, i.relevance_score, i.published_at, i.downstream_action
  FROM items i JOIN sources s ON i.source_id = s.id
  WHERE i.relevance_score >= 25
  ORDER BY i.relevance_score DESC, i.fetched_at DESC LIMIT 15
''').fetchall()
items = []
for r in rows:
    priority = 'high' if (r[2] or 0) >= 45 else 'medium'
    items.append({
        'title': r[0] or '',
        'source': r[1] or '',
        'score': r[2] or 0,
        'date': r[3] or '',
        'action': r[4] or '',
        'priority': priority
    })
print(json.dumps(items))
" 2>/dev/null || echo "[]")
fi

# --- INTELLIGENCE DIGEST (from ResearchBot daily markdown) ---
INTEL_DIGEST_JSON="{}"
DIGEST=$(ls -t "$HOME/qsl-swarm/CABINET/researchbot/output/"*.md 2>/dev/null | head -1)
if [ -f "$DIGEST" ]; then
  INTEL_DIGEST_JSON=$(python3 -c "
import re, json, sys, os
digest_path = '$DIGEST'
digest_date = os.path.basename(digest_path).replace('.md', '')
with open(digest_path) as f:
    content = f.read()
# Extract metrics
items_today = 0
high_count = 0
medium_count = 0
for line in content.splitlines():
    m = re.match(r'- Items fetched today: (\d+)', line)
    if m: items_today = int(m.group(1))
    m = re.match(r'- High priority: (\d+)', line)
    if m: high_count = int(m.group(1))
    m = re.match(r'- Medium priority: (\d+)', line)
    if m: medium_count = int(m.group(1))
    m = re.match(r'## HIGH PRIORITY \((\d+) items?\)', line)
    if m: high_count = max(high_count, int(m.group(1)))
    m = re.match(r'## MEDIUM PRIORITY \((\d+) items?\)', line)
    if m: medium_count = max(medium_count, int(m.group(1)))
# Extract top headlines (bold lines under HIGH or MEDIUM sections)
top_items = []
for m in re.finditer(r'- \*\*(.+?)\*\*', content):
    title = m.group(1).strip()
    if title and len(top_items) < 3:
        top_items.append(title[:120])
print(json.dumps({
    'digest_date': digest_date,
    'items_today': items_today,
    'high_priority': high_count,
    'medium_priority': medium_count,
    'top_items': top_items,
    'next_fetch': 'in 4h'
}))
" 2>/dev/null || echo "{}")
fi

# --- MILESTONES ---
MILESTONES_JSON=$(python3 -c "
import json
milestones = [
    {'text': 'ERC-8004 Agent ID 30013 registered on Base', 'date': '2026-03-12', 'done': True},
    {'text': 'CrawDaddy ACP seller deployed', 'date': '2026-03-12', 'done': True},
    {'text': 'Bastion Conway automaton first boot', 'date': '2026-03-12', 'done': True},
    {'text': 'SN61 miner migrated to Hostinger', 'date': '2026-03-21', 'done': True},
    {'text': 'Bastion OOM fix + circuit breaker', 'date': '2026-03-21', 'done': True},
    {'text': 'ResearchBot Phase 1 deployed', 'date': '2026-03-22', 'done': True},
    {'text': 'CrawDaddy accuracy corpus built', 'date': '2026-03-22', 'done': True},
    {'text': 'Swarm Dashboard live', 'date': '2026-03-22', 'done': True},
    {'text': 'CrawDaddy v2 genesis wiring', 'date': '', 'done': False},
    {'text': 'Bastion first autonomous scan', 'date': '', 'done': False},
]
print(json.dumps(milestones))
" 2>/dev/null || echo "[]")

# --- SYSTEM HEALTH ---
EC2_CPU=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%.1f%%", $2}' 2>/dev/null || echo "—")
EC2_RAM_INFO=$(free -m 2>/dev/null | awk '/Mem:/ {printf "%dM / %dM (%.0f%%)", $3, $2, $3/$2*100}' || echo "—")
EC2_DISK=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}' || echo "—")

# Watchdog health
SELLER_WD_OK=false
SELLER_WD_MSG="—"
SELLER_WD_LOG="$HOME/crawdaddy-security/logs/watchdog.log"
if [ -f "$SELLER_WD_LOG" ]; then
  SELLER_WD_LAST=$(tail -1 "$SELLER_WD_LOG" 2>/dev/null || echo "")
  if [ -n "$SELLER_WD_LAST" ]; then
    SELLER_WD_OK=true
    SELLER_WD_MSG=$(echo "$SELLER_WD_LAST" | cut -c1-60)
  fi
fi

BASTION_WD_OK=false
BASTION_WD_MSG="—"
BASTION_WD_LOG="$HOME/crawdaddy-security/logs/bastion-watchdog.log"
if [ -f "$BASTION_WD_LOG" ]; then
  BASTION_WD_LAST=$(tail -1 "$BASTION_WD_LOG" 2>/dev/null || echo "")
  if [ -n "$BASTION_WD_LAST" ]; then
    BASTION_WD_OK=true
    BASTION_WD_MSG=$(echo "$BASTION_WD_LAST" | cut -c1-60)
  fi
fi

HOSTINGER_STATUS_STR="unreachable"
if [ "$HOSTINGER_REACHABLE" = true ]; then
  HOSTINGER_STATUS_STR="reachable"
fi

COLLECT_END=$(date +%s)
COLLECT_DURATION="$((COLLECT_END - COLLECT_START))s"

# --- BUILD JSON ---
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Write env vars to temp file, let Python do all JSON construction
_ENVFILE=$(mktemp)
cat > "$_ENVFILE" <<ENVEOF
TIMESTAMP=$TIMESTAMP
SELLER_STATUS=$SELLER_STATUS
SELLER_RAM=$SELLER_RAM
SELLER_UPTIME=$SELLER_UPTIME
BASTION_STATUS=$BASTION_STATUS
BASTION_RAM=$BASTION_RAM
BASTION_UPTIME=$BASTION_UPTIME
RB_STATUS=$RB_STATUS
RB_RAM=$RB_RAM
RB_UPTIME=$RB_UPTIME
MINER_STATUS=$MINER_STATUS
MINER_RAM=$MINER_RAM
MINER_RUNNING=$MINER_RUNNING
CONWAY_CREDITS=$CONWAY_CREDITS
CONWAY_TIER=$CONWAY_TIER
CRAWDADDY_BALANCE=$CRAWDADDY_BALANCE
BASTION_BALANCE=$BASTION_BALANCE
EC2_CPU=$EC2_CPU
EC2_RAM=$EC2_RAM_INFO
EC2_DISK=$EC2_DISK
HOSTINGER_STATUS=$HOSTINGER_STATUS_STR
HOSTINGER_REACHABLE=$HOSTINGER_REACHABLE
SELLER_WD_OK=$SELLER_WD_OK
BASTION_WD_OK=$BASTION_WD_OK
COLLECT_DURATION=$COLLECT_DURATION
ENVEOF

# Watchdog messages may have special chars — write separately
echo "SELLER_WD_MSG=$SELLER_WD_MSG" >> "$_ENVFILE"
echo "BASTION_WD_MSG=$BASTION_WD_MSG" >> "$_ENVFILE"

# Intel, milestones, and digest JSON passed via files
_INTEL_FILE=$(mktemp)
_MILES_FILE=$(mktemp)
_DIGEST_FILE=$(mktemp)
echo "$INTEL_JSON" > "$_INTEL_FILE"
echo "$MILESTONES_JSON" > "$_MILES_FILE"
echo "$INTEL_DIGEST_JSON" > "$_DIGEST_FILE"

python3 - "$_ENVFILE" "$_INTEL_FILE" "$_MILES_FILE" "$OUTPUT" "$_DIGEST_FILE" <<'PYEOF'
import json, sys

def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if '=' in line:
                k, v = line.split('=', 1)
                env[k] = v
    return env

env = load_env(sys.argv[1])

with open(sys.argv[2]) as f:
    intel = json.loads(f.read().strip() or '[]')
with open(sys.argv[3]) as f:
    milestones = json.loads(f.read().strip() or '[]')
with open(sys.argv[5]) as f:
    intel_digest = json.loads(f.read().strip() or '{}')

def b(val):
    return val == 'true'

data = {
    'timestamp': env.get('TIMESTAMP', ''),
    'cabinet': [
        {
            'name': 'CrawDaddy',
            'role': 'CSO \u2014 Gen 1',
            'status': env.get('SELLER_STATUS', 'unknown'),
            'host': 'EC2',
            'ram': env.get('SELLER_RAM', '\u2014'),
            'uptime': env.get('SELLER_UPTIME', '\u2014'),
            'note': 'ACP seller on Virtuals'
        },
        {
            'name': 'Bastion',
            'role': 'CIO \u2014 Gen 2',
            'status': env.get('BASTION_STATUS', 'unknown'),
            'host': 'EC2',
            'ram': env.get('BASTION_RAM', '\u2014'),
            'uptime': env.get('BASTION_UPTIME', '\u2014'),
            'note': 'Paused — pending ContentBot + revenue milestone'
        },
        {
            'name': 'ResearchBot',
            'role': 'CDO \u2014 Intelligence',
            'status': env.get('RB_STATUS', 'unknown'),
            'host': 'EC2',
            'ram': env.get('RB_RAM', '\u2014'),
            'uptime': env.get('RB_UPTIME', '\u2014'),
            'note': 'Feed aggregation + daily digest'
        },
        {
            'name': 'SN61 Miner',
            'role': 'Revenue \u2014 BitTensor',
            'status': env.get('MINER_STATUS', 'unknown'),
            'host': 'Hostinger',
            'ram': env.get('MINER_RAM', '\u2014'),
            'uptime': '\u2014',
            'note': 'UID 57 Finney mainnet'
        }
    ],
    'treasury': {
        'conway_credits': env.get('CONWAY_CREDITS', '\u2014'),
        'conway_tier': env.get('CONWAY_TIER', '\u2014'),
        'crawdaddy_address': '0x25B50fEd69175e474F9702C0613413F8323809a8',
        'crawdaddy_balance': env.get('CRAWDADDY_BALANCE', '\u2014'),
        'bastion_address': '0xEEF60d4E36EdcfE75b07ffA8a492212660452DD4',
        'bastion_balance': env.get('BASTION_BALANCE', '\u2014')
    },
    'intel_feed': intel,
    'intelligence': intel_digest,
    'milestones': milestones,
    'health': {
        'ec2_cpu': env.get('EC2_CPU', '\u2014'),
        'ec2_ram': env.get('EC2_RAM', '\u2014'),
        'ec2_disk': env.get('EC2_DISK', '\u2014'),
        'ec2_status': 'running',
        'hostinger_status': env.get('HOSTINGER_STATUS', 'unreachable'),
        'hostinger_reachable': b(env.get('HOSTINGER_REACHABLE', 'false')),
        'miner_status': env.get('MINER_STATUS', 'unknown'),
        'miner_running': b(env.get('MINER_RUNNING', 'false')),
        'seller_watchdog': env.get('SELLER_WD_MSG', '\u2014'),
        'seller_watchdog_ok': b(env.get('SELLER_WD_OK', 'false')),
        'bastion_watchdog': env.get('BASTION_WD_MSG', '\u2014'),
        'bastion_watchdog_ok': b(env.get('BASTION_WD_OK', 'false')),
        'collect_duration': env.get('COLLECT_DURATION', '\u2014')
    }
}

with open(sys.argv[4], 'w') as f:
    json.dump(data, f, indent=2)
PYEOF

rm -f "$_ENVFILE" "$_INTEL_FILE" "$_MILES_FILE" "$_DIGEST_FILE"

echo "[$(date)] Collected status → $OUTPUT ($COLLECT_DURATION)"
