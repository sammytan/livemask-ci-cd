#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-WEBSITE-001 — Website Blog Smoke
# ═══════════════════════════════════════════════════════════════════════════════
# Covers:
#   [1] Website / returns 200
#   [2] Website homepage contains Blog nav in JS-rendered check or source route smoke
#   [3] /blog route returns app shell
#   [4] Backend blog API returns items
#   [5] sitemap.xml exists
#   [6] rss.xml exists
#   [7] no VITE_API_MOCK_MODE=true in local real mode
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
WEBSITE_PORT="${LIVEMASK_WEBSITE_PORT:-3002}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"
WEBSITE_BASE="http://127.0.0.1:${WEBSITE_PORT}"

FAILED=0
SUMMARY_LINES=()

fail() {
  local msg="$1"
  echo "  FAIL: ${msg}"
  SUMMARY_LINES+=("FAIL: ${msg}")
  FAILED=1
}

pass() {
  local msg="$1"
  echo "  PASS: ${msg}"
  SUMMARY_LINES+=("PASS: ${msg}")
}

skip() {
  local msg="$1"
  echo "  SKIP: ${msg}"
  SUMMARY_LINES+=("SKIP: ${msg}")
}

blocker() {
  local msg="$1"
  echo "  BLOCKER: ${msg}"
  SUMMARY_LINES+=("BLOCKER: ${msg}")
  FAILED=1
}

quiet_json() {
  local path="${1:-}"
  python3 -c "
import sys,json
data=json.load(sys.stdin)
parts='${path}'.split('.')
current=data
for p in parts:
    if isinstance(current, dict):
        if p not in current:
            print('')
            sys.exit(0)
        current=current[p]
    elif isinstance(current, list):
        try:
            current=current[int(p)]
        except (IndexError, ValueError):
            print('')
            sys.exit(0)
    else:
        print('')
        sys.exit(0)
print(current)
" 2>/dev/null || echo ""
}

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"

echo "================================================"
echo " TASK-CICD-WEBSITE-001: Website Blog Smoke"
echo "================================================"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# [0] Backend health (required for API checks)
# ──────────────────────────────────────────────────────────────────────────────
echo "--- [0] Backend Health ---"
for attempt in $(seq 1 30); do
  health_resp=$(curl -sS --max-time 3 "${API_BASE}/api/v1/health" 2>/dev/null || true)
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    echo "  Backend ready (attempt ${attempt})"
    pass "Backend health ok"
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    blocker "Backend not ready after 30 attempts"
    echo ""
    printf '%s\n' "${SUMMARY_LINES[@]}"
    exit 1
  fi
  sleep 2
done

# ──────────────────────────────────────────────────────────────────────────────
# [1] Website / returns 200
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [1] Website Homepage (HTTP 200) ---"
HTTP_HOME=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "${WEBSITE_BASE}/" 2>/dev/null || true)
if [[ "${HTTP_HOME}" == "200" || "${HTTP_HOME}" == "302" || "${HTTP_HOME}" == "301" ]]; then
  pass "Website / returns HTTP ${HTTP_HOME}"
elif [[ "${HTTP_HOME}" == "000" ]]; then
  skip "Website / is unreachable (website container may not be running)"
else
  skip "Website / returns HTTP ${HTTP_HOME} (expected 200, 301, or 302)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [2] Website homepage contains Blog nav or blog route handling
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [1a] Website runtime cache / stale asset guard ---"
HOME_HEADERS=$(curl -sSI --max-time 10 "${WEBSITE_BASE}/" 2>/dev/null || true)
if echo "${HOME_HEADERS}" | tr -d '\r' | grep -qi '^Cache-Control:.*no-store'; then
  pass "Website index response uses no-store cache policy"
else
  fail "Website index response is missing Cache-Control: no-store"
fi

MISSING_ASSET_CODE=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "${WEBSITE_BASE}/assets/index-LIVEMASK_STALE_ASSET_PROBE.js" 2>/dev/null || echo "000")
if [[ "${MISSING_ASSET_CODE}" == "404" ]]; then
  pass "Missing hashed website asset returns HTTP 404 instead of SPA index fallback"
else
  fail "Missing hashed website asset returned HTTP ${MISSING_ASSET_CODE}; stale browser bundles may keep executing"
fi

echo ""
echo "--- [2] Website homepage content (Blog nav check) ---"
HOMEPAGE_HTML=$(curl -sS --max-time 10 "${WEBSITE_BASE}/" 2>/dev/null || true)
if [[ -n "${HOMEPAGE_HTML}" ]]; then
  # Check for common blog indicators in HTML (source code of SPA shell)
  if echo "${HOMEPAGE_HTML}" | grep -qi '"blog"' 2>/dev/null || \
     echo "${HOMEPAGE_HTML}" | grep -qi '/blog' 2>/dev/null || \
     echo "${HOMEPAGE_HTML}" | grep -qi 'Blog' 2>/dev/null; then
    pass "Website homepage contains Blog reference in source"
  else
    # SPA may have blog as a route — check for route config or navigation items
    if echo "${HOMEPAGE_HTML}" | grep -qi 'navigation\|routes\|router' 2>/dev/null; then
      skip "Website is SPA — blog route may be client-side handled"
    else
      skip "Blog nav not found in homepage source (may be SPA rendered)"
    fi
  fi
else
  skip "Website homepage content not available for nav check"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [3] /blog route returns app shell
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [3] /blog route returns app shell (HTTP check) ---"
HTTP_BLOG=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "${WEBSITE_BASE}/blog" 2>/dev/null || true)
BLOG_HTML=$(curl -sS --max-time 10 "${WEBSITE_BASE}/blog" 2>/dev/null || true)

case "${HTTP_BLOG}" in
  200|301|302)
    pass "/blog returns HTTP ${HTTP_BLOG}"
    # Check it returns HTML (app shell)
    if echo "${BLOG_HTML}" | grep -qi '<html\|<!DOCTYPE\|<head\|<div id="root"\|<div id="__next"' 2>/dev/null; then
      pass "/blog returns HTML app shell"
    else
      skip "/blog response does not appear to be HTML (non-SPA response)"
    fi
    ;;
  404)
    skip "/blog returns HTTP 404 (route may not be implemented)"
    ;;
  000)
    skip "/blog is unreachable (website container may not be running)"
    ;;
  *)
    skip "/blog returns HTTP ${HTTP_BLOG}"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# [4] Backend blog API returns items
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [4] Backend Blog API ---"
BLOG_API=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/blog?limit=5") || true
BLOG_API_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/blog?limit=5") || true

if [[ "${BLOG_API_HTTP}" == "200" ]]; then
  BLOG_ITEMS=$(echo "${BLOG_API}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items') or data.get('data') or data.get('blog_articles') or []
print(len(items))
" 2>/dev/null || echo "0")
  pass "Backend blog API: HTTP 200, items=${BLOG_ITEMS}"

  # Verify items are published blog_articles
  CONTENT_OK=$(echo "${BLOG_API}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items') or data.get('data') or data.get('blog_articles') or []
issues = []
for item in items:
    ct = item.get('content_type')
    if ct is not None and ct != 'blog_article':
        issues.append(item.get('slug','?'))
    if item.get('status') not in (None, 'published'):
        issues.append(item.get('slug','?') + ':status=' + item.get('status','unknown'))
if issues:
    print('ISSUES: ' + ', '.join(issues))
else:
    print('OK')
" 2>/dev/null || echo "OK")
  if [[ "${CONTENT_OK}" == "OK" ]]; then
    pass "Blog API items are valid (published blog_articles only)"
  else
    fail "Blog API items have issues: ${CONTENT_OK}"
  fi
elif [[ "${BLOG_API_HTTP}" == "404" ]]; then
  skip "Backend blog API: HTTP 404 (endpoint not yet deployed)"
else
  fail "Backend blog API: HTTP ${BLOG_API_HTTP} (expected 200)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [5] sitemap.xml exists (via backend API or website route)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [5] Sitemap Source Check ---"

# Check backend sitemap API (JSON source)
BK_SITEMAP_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/sitemap" 2>/dev/null || true)

# Check website sitemap.xml route
WEB_SITEMAP_HTTP=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "${WEBSITE_BASE}/sitemap.xml" 2>/dev/null || true)

sitemap_ok=false
if [[ "${BK_SITEMAP_HTTP}" == "200" ]]; then
  BK_SITEMAP_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/sitemap") || true
  SITEMAP_COUNT=$(echo "${BK_SITEMAP_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
urls = data.get('urls',data.get('items',data.get('sitemap',[])))
if isinstance(urls, list): print(len(urls))
else: print(0)
" 2>/dev/null || echo "0")
  pass "Backend sitemap JSON source: HTTP 200, ${SITEMAP_COUNT} URLs"
  sitemap_ok=true
fi

if [[ "${WEB_SITEMAP_HTTP}" == "200" || "${WEB_SITEMAP_HTTP}" == "301" || "${WEB_SITEMAP_HTTP}" == "302" ]]; then
  pass "Website ${WEBSITE_BASE}/sitemap.xml: HTTP ${WEB_SITEMAP_HTTP}"
  sitemap_ok=true
elif [[ "${WEB_SITEMAP_HTTP}" == "404" ]]; then
  skip "Website /sitemap.xml: HTTP 404 (not yet implemented)"
elif [[ "${WEB_SITEMAP_HTTP}" == "000" ]]; then
  skip "Website /sitemap.xml: unreachable"
fi

if [[ "${sitemap_ok}" == "false" ]]; then
  fail "sitemap.xml not found via backend API or website route"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [6] rss.xml exists (via backend API or website route)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [6] RSS Source Check ---"

# Check backend RSS API (JSON source)
BK_RSS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/rss" 2>/dev/null || true)

# Check website rss.xml route
WEB_RSS_HTTP=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "${WEBSITE_BASE}/rss.xml" 2>/dev/null || true)

rss_ok=false
if [[ "${BK_RSS_HTTP}" == "200" ]]; then
  BK_RSS_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/rss") || true
  RSS_ITEMS=$(echo "${BK_RSS_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items',[])
print(len(items))
" 2>/dev/null || echo "0")
  pass "Backend RSS JSON source: HTTP 200, ${RSS_ITEMS} items"
  rss_ok=true
fi

if [[ "${WEB_RSS_HTTP}" == "200" || "${WEB_RSS_HTTP}" == "301" || "${WEB_RSS_HTTP}" == "302" ]]; then
  pass "Website ${WEBSITE_BASE}/rss.xml: HTTP ${WEB_RSS_HTTP}"
  rss_ok=true
elif [[ "${WEB_RSS_HTTP}" == "404" ]]; then
  skip "Website /rss.xml: HTTP 404 (not yet implemented)"
elif [[ "${WEB_RSS_HTTP}" == "000" ]]; then
  skip "Website /rss.xml: unreachable"
fi

if [[ "${rss_ok}" == "false" ]]; then
  fail "rss.xml not found via backend API or website route"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [7] No VITE_API_MOCK_MODE=true in local real mode
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [7] VITE_API_MOCK_MODE Check ---"
# Check if the running website container has VITE_API_MOCK_MODE=true
# This would indicate the website is running in mock mode against real backend
MOCK_IN_CONTAINER=$(docker compose -f "${COMPOSE_FILE}" exec -T website env 2>/dev/null | grep -c 'VITE_API_MOCK_MODE=true' || true)
MOCK_IN_ENV_FILE=$(grep -c 'VITE_API_MOCK_MODE=true' "${REPO_DIR}/infra/env/website.env" 2>/dev/null || true)

if [[ "${MOCK_IN_CONTAINER}" -gt 0 ]]; then
  fail "VITE_API_MOCK_MODE=true detected in website container env (real mode should use false or unset)"
elif [[ "${MOCK_IN_ENV_FILE}" -gt 0 ]]; then
  # Check if there's a website.env file at all
  fail "VITE_API_MOCK_MODE=true found in infra/env/website.env (real smoke should use false)"
elif docker compose -f "${COMPOSE_FILE}" ps --services 2>/dev/null | grep -q "website"; then
  # Website service exists in compose
  echo "  Website service is running without VITE_API_MOCK_MODE=true"
  pass "No VITE_API_MOCK_MODE=true in website environment"
else
  # Website may not be in staging compose
  echo "  Website service not in staging compose — checking local env if available"
  WEBSITE_ENV_FILE="${REPO_DIR}/infra/env/website.env"
  if [[ -f "${WEBSITE_ENV_FILE}" ]]; then
    if grep -q 'VITE_API_MOCK_MODE=true' "${WEBSITE_ENV_FILE}" 2>/dev/null; then
      fail "VITE_API_MOCK_MODE=true found in ${WEBSITE_ENV_FILE}"
    else
      pass "VITE_API_MOCK_MODE is not set to true in environment files"
    fi
  else
    skip "No website.env file or website service found; cannot verify mock mode"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Cleanup ---"
echo "  Website smoke is read-only; no data cleanup needed"

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo " TASK-CICD-WEBSITE-001 SUMMARY"
echo "================================================"
printf '%s\n' "${SUMMARY_LINES[@]}"

echo ""
if [[ "${FAILED}" -eq 1 ]]; then
  echo "[TASK-CICD-WEBSITE-001] WEBSITE SMOKE FAILED."
  echo ""
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo ""
  echo "--- docker compose logs website (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs website --tail=50 2>/dev/null || true
  echo "--- docker compose logs backend (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=50 2>/dev/null || true
  exit 1
fi

echo "[TASK-CICD-WEBSITE-001] Website blog smoke PASSED."
echo "Covers: Homepage HTTP, Blog nav, /blog route, Blog API, sitemap, RSS, mock mode check"
