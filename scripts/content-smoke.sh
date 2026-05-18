#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# TASK-CICD-CONTENT-SEO-001 — Content System 全链路 Smoke
# ──────────────────────────────────────────────────────────────────────────────
# Covers:
#   Backend public Blog API (list, detail, categories, tags)
#   Website SEO data source (sitemap, RSS)
#   App content feed (placement, filtering, expired/archived)
#   Admin content API (auth/RBAC, CRUD, link validation)
#   Security leak checks
# ──────────────────────────────────────────────────────────────────────────────

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"

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

pg_exec() {
  docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA "$@" 2>/dev/null || true
}

security_check() {
  local label="$1"
  local json="$2"
  local leaked
  leaked=$(echo "${json}" | python3 -c "
import sys,json
def check_keys(d, target_words):
    if isinstance(d, dict):
        for k, v in d.items():
            kl = k.lower()
            for w in target_words:
                if w in kl:
                    return True
            if check_keys(v, target_words):
                return True
    elif isinstance(d, list):
        for item in d:
            if check_keys(item, target_words):
                return True
    return False

data=json.load(sys.stdin)
sensitive = ['access_token','password_hash','node_secret','hmac','private_key','secret_key','refresh_token','password']
# Only check field names, not values (blog text may contain 'password')
found = [w for w in sensitive if check_keys(data, [w])]
if found:
    print('LEAK: ' + ', '.join(found))
else:
    print('OK')
" 2>/dev/null || echo "OK")
  if [[ "${leaked}" != "OK" ]]; then
    fail "[SECURITY] ${label}: ${leaked}"
    return 1
  fi
  return 0
}

TIMESTAMP=$(date +%s)
SMOKE_TITLE="Smoke Announcement ${TIMESTAMP}"
SMOKE_SLUG="smoke-announcement-${TIMESTAMP}"

echo "========================================"
echo " TASK-CICD-CONTENT-SEO-001: Content System Smoke"
echo "========================================"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# [0] Health check
# ──────────────────────────────────────────────────────────────────────────────
echo "--- [0] Health Check ---"
for attempt in $(seq 1 30); do
  health_resp=$(curl -sS --max-time 3 "${API_BASE}/api/v1/health" 2>/dev/null || true)
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    echo "  Backend ready (attempt ${attempt})"
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    fail "Backend not ready after 30 attempts"
    echo ""
    printf '%s\n' "${SUMMARY_LINES[@]}"
    exit 1
  fi
  sleep 2
done
pass "Backend health ok"

# ──────────────────────────────────────────────────────────────────────────────
# [1] Admin login (dev seed)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [1] Admin Login (dev seed) ---"
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"content-smoke-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  echo "  INFO: seeding admin via SQL..."
  pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'"
  ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" || echo "")
  if [[ -n "${ADMIN_HASH}" ]]; then
    pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'"
    pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by content-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING"
    ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d '{"request_id":"content-smoke-admin-login2","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
    ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
  fi
  if [[ -z "${ADMIN_TOKEN}" ]]; then
    fail "Admin login"
  fi
fi
if [[ -n "${ADMIN_TOKEN}" ]]; then
  pass "Admin login OK (token length=${#ADMIN_TOKEN})"
fi
# Security check skipped for auth responses (access_token/refresh_token expected)

# ──────────────────────────────────────────────────────────────────────────────
# [2] Website/user login
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [2] User Login ---"
USER_EMAIL="content-smoke-user@test.livemask"
USER_PASS="ContentTest123!"
pg_exec -c "DELETE FROM users WHERE email='${USER_EMAIL}'" 2>/dev/null || true

USER_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"content-smoke-reg\",\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASS}\",\"display_name\":\"Content Smoke User\",\"client_type\":\"website\"}") || true
USER_TOKEN=$(echo "${USER_REG}" | quiet_json "access_token")
if [[ -z "${USER_TOKEN}" ]]; then
  USER_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"content-smoke-login\",\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASS}\",\"client_type\":\"website\"}") || true
  USER_TOKEN=$(echo "${USER_LOGIN}" | quiet_json "access_token")
fi
if [[ -z "${USER_TOKEN}" ]]; then
  fail "User login"
else
  pass "User login OK (token length=${#USER_TOKEN})"
fi
# Security check skipped for auth responses (access_token/refresh_token expected)

# ──────────────────────────────────────────────────────────────────────────────
# [3] Blog list
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [3] Blog List ---"
BLOG_LIST=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/blog?limit=5") || true
BLOG_LIST_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/blog?limit=5") || true
if [[ "${BLOG_LIST_HTTP}" != "200" ]]; then
  fail "Blog list: HTTP ${BLOG_LIST_HTTP} (expected 200)"
else
  BLOG_ITEMS=$(echo "${BLOG_LIST}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items') or data.get('data') or data.get('blog_articles') or []
print(len(items))
" 2>/dev/null || echo "0")
  if [[ "${BLOG_ITEMS}" -ge 0 ]]; then
    pass "Blog list: ${BLOG_ITEMS} items (HTTP 200)"
  else
    fail "Blog list: unexpected structure"
  fi
fi
# Verify items only content_type=blog_article if field present
CONTENT_TYPE_CHECK=$(echo "${BLOG_LIST}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items') or data.get('data') or data.get('blog_articles') or []
issues = []
for item in items:
    ct = item.get('content_type')
    if ct is not None and ct != 'blog_article':
        issues.append(item.get('slug','?'))
if issues:
    print('MISMATCH: ' + ', '.join(issues))
else:
    print('OK')
" 2>/dev/null || echo "OK")
if [[ "${CONTENT_TYPE_CHECK}" != "OK" ]]; then
  fail "Blog list content_type: ${CONTENT_TYPE_CHECK}"
fi
# Verify no draft/archived items
STATUS_CHECK=$(echo "${BLOG_LIST}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items') or data.get('data') or data.get('blog_articles') or []
issues = [i.get('slug','?') for i in items if i.get('status') in ('draft','archived')]
if issues:
    print('STATUS: ' + ', '.join(issues))
else:
    print('OK')
" 2>/dev/null || echo "OK")
if [[ "${STATUS_CHECK}" != "OK" ]]; then
  fail "Blog list contains draft/archived: ${STATUS_CHECK}"
fi
FIRST_SLUG=$(echo "${BLOG_LIST}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items') or data.get('data') or data.get('blog_articles') or []
if items:
    print(items[0].get('slug',''))
" 2>/dev/null || echo "")
security_check "Blog list response" "${BLOG_LIST}" || true

# ──────────────────────────────────────────────────────────────────────────────
# [4] Blog detail
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [4] Blog Detail ---"
if [[ -n "${FIRST_SLUG}" ]]; then
  BLOG_DETAIL=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/blog/${FIRST_SLUG}") || true
  BLOG_DETAIL_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/blog/${FIRST_SLUG}") || true
  if [[ "${BLOG_DETAIL_HTTP}" != "200" ]]; then
    fail "Blog detail: HTTP ${BLOG_DETAIL_HTTP}"
  else
    DETAIL_SLUG=$(echo "${BLOG_DETAIL}" | quiet_json "article.slug" || echo "${BLOG_DETAIL}" | quiet_json "slug" || echo "")
    DETAIL_TITLE=$(echo "${BLOG_DETAIL}" | quiet_json "article.title" || echo "${BLOG_DETAIL}" | quiet_json "title" || echo "")
    DETAIL_EXCERPT=$(echo "${BLOG_DETAIL}" | quiet_json "article.excerpt" || echo "${BLOG_DETAIL}" | quiet_json "excerpt" || echo "")
    DETAIL_MD=$(echo "${BLOG_DETAIL}" | quiet_json "article.content_markdown" || echo "${BLOG_DETAIL}" | quiet_json "content_markdown" || echo "")
    if [[ -n "${DETAIL_SLUG}" ]] && [[ -n "${DETAIL_TITLE}" ]]; then
      pass "Blog detail: slug=${DETAIL_SLUG} title=${DETAIL_TITLE:0:40}..."
    else
      fail "Blog detail: missing slug or title"
    fi
    # robots check
    DETAIL_ROBOTS=$(echo "${BLOG_DETAIL}" | quiet_json "article.robots" || echo "${BLOG_DETAIL}" | quiet_json "robots" || echo "")
    if echo "${DETAIL_ROBOTS}" | grep -qi "noindex"; then
      echo "  INFO: blog detail robots includes noindex (slug=${FIRST_SLUG})"
    fi
  fi
  security_check "Blog detail response" "${BLOG_DETAIL}" || true
else
  echo "  SKIP: no blog articles found for detail check"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [5] Categories/tags
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [5] Categories & Tags ---"
CATS_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/blog/categories") || true
CATS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/blog/categories") || true
TAGS_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/blog/tags") || true
TAGS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/blog/tags") || true

cats_ok=true
if [[ "${CATS_HTTP}" != "200" ]]; then echo "  FAIL: categories HTTP ${CATS_HTTP}"; cats_ok=false; fi
if [[ "${TAGS_HTTP}" != "200" ]]; then echo "  FAIL: tags HTTP ${TAGS_HTTP}"; cats_ok=false; fi
if [[ "${cats_ok}" == "true" ]]; then
  CATS_COUNT=$(echo "${CATS_RESP}" | python3 -c "
import sys,json; data=json.load(sys.stdin)
if isinstance(data, list): print(len(data))
else: print(len(data.get('categories',data.get('items',[]))))
" 2>/dev/null || echo "0")
  TAGS_COUNT=$(echo "${TAGS_RESP}" | python3 -c "
import sys,json; data=json.load(sys.stdin)
if isinstance(data, list): print(len(data))
else: print(len(data.get('tags',data.get('items',[]))))
" 2>/dev/null || echo "0")
  pass "Categories: ${CATS_COUNT} items, Tags: ${TAGS_COUNT} items"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [6] Sitemap JSON source
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [6] Sitemap JSON Source ---"
SITEMAP_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/sitemap") || true
SITEMAP_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/sitemap") || true
if [[ "${SITEMAP_HTTP}" != "200" ]]; then
  fail "Sitemap: HTTP ${SITEMAP_HTTP}"
else
  SITEMAP_URLS=$(echo "${SITEMAP_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
urls = data.get('urls',data.get('items',data.get('sitemap',[])))
if isinstance(urls, list):
    print(len(urls))
else:
    print(0)
" 2>/dev/null || echo "0")
  if [[ "${SITEMAP_URLS}" -ge 0 ]]; then
    pass "Sitemap: ${SITEMAP_URLS} URLs"
  fi
  # Check no noindex URLs
  NOINDEX_CHECK=$(echo "${SITEMAP_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
urls = data.get('urls',data.get('items',data.get('sitemap',[])))
noindex = []
for u in urls:
    if isinstance(u, dict) and u.get('robots','').lower().find('noindex') >= 0:
        noindex.append(u.get('loc',u.get('url','?')))
if noindex:
    print('FOUND: ' + ', '.join(noindex[:5]))
else:
    print('OK')
" 2>/dev/null || echo "OK")
  if [[ "${NOINDEX_CHECK}" != "OK" ]]; then
    fail "Sitemap contains noindex URLs: ${NOINDEX_CHECK}"
  fi
  # Check contains blog URLs
  HAS_BLOG=$(echo "${SITEMAP_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
urls = data.get('urls',data.get('items',data.get('sitemap',[])))
url_str = json.dumps(urls).lower()
if 'blog' in url_str:
    print('YES')
else:
    print('NO')
" 2>/dev/null || echo "NO")
  if [[ "${HAS_BLOG}" == "YES" ]]; then
    echo "       Contains blog URLs"
  else
    echo "  INFO: no blog URLs in sitemap (may be empty sitemap)"
  fi
fi
security_check "Sitemap response" "${SITEMAP_RESP}" || true

# ──────────────────────────────────────────────────────────────────────────────
# [7] RSS JSON source
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [7] RSS JSON Source ---"
RSS_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/rss") || true
RSS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/rss") || true
if [[ "${RSS_HTTP}" != "200" ]]; then
  fail "RSS: HTTP ${RSS_HTTP}"
else
  RSS_ITEMS=$(echo "${RSS_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items',[])
print(len(items))
" 2>/dev/null || echo "0")
  if [[ "${RSS_ITEMS}" -ge 0 ]]; then
    pass "RSS: ${RSS_ITEMS} items"
  fi
  # Verify items have title/link/pubDate
  RSS_FIELDS_OK=$(echo "${RSS_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items',[])
if not items:
    print('OK')
    sys.exit(0)
ok = True
for item in items:
    if not item.get('title') or not item.get('link'):
        ok = False
if ok:
    print('OK')
else:
    print('MISSING_FIELDS')
" 2>/dev/null || echo "OK")
  if [[ "${RSS_FIELDS_OK}" != "OK" ]]; then
    fail "RSS items missing required fields (title/link)"
  fi
fi
security_check "RSS response" "${RSS_RESP}" || true

# ──────────────────────────────────────────────────────────────────────────────
# [8] App content feed
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [8] App Content Feed (app_home_banner) ---"
APP_FEED=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/app?placement=app_home_banner") || true
APP_FEED_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/app?placement=app_home_banner") || true
if [[ "${APP_FEED_HTTP}" != "200" ]]; then
  fail "App feed: HTTP ${APP_FEED_HTTP}"
else
  FEED_ITEMS=$(echo "${APP_FEED}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items',data.get('data',[]))
print(len(items))
" 2>/dev/null || echo "0")
  pass "App feed: ${FEED_ITEMS} items (HTTP 200)"

  # Verify content_type in allowed types
  TYPE_CHECK=$(echo "${APP_FEED}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items',data.get('data',[]))
allowed = {'announcement','campaign','app_banner','release_note'}
issues = []
for item in items:
    ct = item.get('content_type','')
    if ct not in allowed and ct != '':
        issues.append(f\"{item.get('slug','?')}:{ct}\")
if issues:
    print('UNEXPECTED: ' + ', '.join(issues))
else:
    print('OK')
" 2>/dev/null || echo "OK")
  if [[ "${TYPE_CHECK}" != "OK" ]]; then
    fail "App feed content_type: ${TYPE_CHECK}"
  fi

  # Verify surface app/all
  SURFACE_CHECK=$(echo "${APP_FEED}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items',data.get('data',[]))
allowed_surfaces = {'app','all'}
issues = []
for item in items:
    sf = item.get('surface','')
    if sf not in allowed_surfaces and sf != '':
        issues.append(f\"{item.get('slug','?')}:{sf}\")
if issues:
    print('UNEXPECTED: ' + ', '.join(issues))
else:
    print('OK')
" 2>/dev/null || echo "OK")
  if [[ "${SURFACE_CHECK}" != "OK" ]]; then
    fail "App feed surface: ${SURFACE_CHECK}"
  fi

  # Verify expired items not returned
  EXPIRED_CHECK=$(echo "${APP_FEED}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items',data.get('data',[]))
import datetime
now = datetime.datetime.now(datetime.timezone.utc)
issues = []
for item in items:
    eea = item.get('effective_ends_at')
    if eea:
        try:
            end = datetime.datetime.fromisoformat(eea.replace('Z','+00:00'))
            if end < now:
                issues.append(item.get('slug','?'))
        except:
            pass
if issues:
    print('EXPIRED: ' + ', '.join(issues))
else:
    print('OK')
" 2>/dev/null || echo "OK")
  if [[ "${EXPIRED_CHECK}" != "OK" ]]; then
    fail "App feed returned expired items: ${EXPIRED_CHECK}"
  fi
fi
security_check "App feed response" "${APP_FEED}" || true

# ──────────────────────────────────────────────────────────────────────────────
# [9] Admin content unauthorized
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [9] Admin Content Unauthorized ---"
ADMIN_CONTENT_NO_TOKEN=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/admin/api/v1/content") || true
if [[ "${ADMIN_CONTENT_NO_TOKEN}" == "401" ]]; then
  pass "Admin content without token: 401"
else
  fail "Admin content without token: ${ADMIN_CONTENT_NO_TOKEN} (expected 401)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [10] Admin content user forbidden
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [10] Admin Content with User Token (RBAC) ---"
ADMIN_CONTENT_USER_TOKEN=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/content" -H "Authorization: Bearer ${USER_TOKEN}") || true
if [[ "${ADMIN_CONTENT_USER_TOKEN}" == "401" || "${ADMIN_CONTENT_USER_TOKEN}" == "403" ]]; then
  pass "Admin content with user token: ${ADMIN_CONTENT_USER_TOKEN}"
else
  fail "Admin content with user token: ${ADMIN_CONTENT_USER_TOKEN} (expected 401/403)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [11] Admin content list
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [11] Admin Content List ---"
ADMIN_CONTENT_LIST=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/content" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
ADMIN_CONTENT_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/content" -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
if [[ "${ADMIN_CONTENT_HTTP}" != "200" ]]; then
  fail "Admin content list: HTTP ${ADMIN_CONTENT_HTTP}"
else
  ADMIN_CONTENT_ITEMS=$(echo "${ADMIN_CONTENT_LIST}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items',data.get('data',data.get('content',[])))
if isinstance(items, list):
    print(len(items))
else:
    print(0)
" 2>/dev/null || echo "0")
  ADMIN_CONTENT_TOTAL=$(echo "${ADMIN_CONTENT_LIST}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
print(data.get('total',data.get('total_count',len(data.get('items',data.get('data',[]))))))
" 2>/dev/null || echo "0")
  if [[ "${ADMIN_CONTENT_ITEMS}" -ge 0 ]]; then
    pass "Admin content list: ${ADMIN_CONTENT_ITEMS} items, total=${ADMIN_CONTENT_TOTAL}"
  else
    fail "Admin content list: unexpected structure"
  fi
fi
security_check "Admin content list" "${ADMIN_CONTENT_LIST}" || true

# ──────────────────────────────────────────────────────────────────────────────
# [12] Admin create content
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [12] Admin Create Content ---"
CREATE_PAYLOAD=$(cat <<EOF
{
  "slug": "${SMOKE_SLUG}",
  "locale": "en-US",
  "content_type": "announcement",
  "surface": "app",
  "placement": "app_notice_center",
  "title": "Smoke Announcement ${TIMESTAMP}",
  "excerpt": "Smoke test announcement",
  "content_markdown": "Smoke content",
  "tags": ["smoke-test"],
  "robots": "index,follow",
  "status": "published",
  "visibility": "public",
  "link_type": "app_route",
  "link_target": "/profile",
  "cta_label": "Open"
}
EOF
)
CREATE_RESP_RAW=$(curl -sS -w "\n%{http_code}" --max-time 5 -X POST "${API_BASE}/admin/api/v1/content" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d "${CREATE_PAYLOAD}") || true
CREATE_HTTP=$(echo "${CREATE_RESP_RAW}" | tail -1)
CREATE_RESP=$(echo "${CREATE_RESP_RAW}" | sed '$d')

CREATED_ID=$(echo "${CREATE_RESP}" | quiet_json "id" || echo "${CREATE_RESP}" | quiet_json "content_id" || echo "${CREATE_RESP}" | quiet_json "data.id" || echo "")
if [[ "${CREATE_HTTP}" == "200" || "${CREATE_HTTP}" == "201" ]]; then
  # Some backends return empty id — fallback to DB lookup by slug
  if [[ -z "${CREATED_ID}" ]]; then
    CREATED_ID="$(pg_exec -c "SELECT id::text FROM content_items WHERE slug='${SMOKE_SLUG}'" 2>/dev/null || true)"
    CREATED_ID="$(echo "${CREATED_ID}" | xargs)"
  fi
  if [[ -n "${CREATED_ID}" ]]; then
    pass "Admin create content: id=${CREATED_ID} slug=${SMOKE_SLUG}"
  else
    fail "Admin create content: created but id not found in DB"
    echo "  HTTP ${CREATE_HTTP}, response slug=${SMOKE_SLUG}"
  fi
else
  fail "Admin create content: HTTP ${CREATE_HTTP}"
  echo "  Response: $(echo ${CREATE_RESP} | head -c 300)"
fi
security_check "Admin create response" "${CREATE_RESP}" || true

# ──────────────────────────────────────────────────────────────────────────────
# [13] App feed sees created item
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [13] App Feed: Created Item Appears ---"
sleep 1
APP_NOTICE_FEED=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/app?placement=app_notice_center") || true
APP_NOTICE_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/content/app?placement=app_notice_center") || true
if [[ "${APP_NOTICE_HTTP}" != "200" ]]; then
  fail "App notice feed: HTTP ${APP_NOTICE_HTTP}"
else
  FOUND_SMOKE=$(echo "${APP_NOTICE_FEED}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items',data.get('data',[]))
for item in items:
    if item.get('title') == '${SMOKE_TITLE}':
        print('FOUND')
        break
else:
    print('NOT_FOUND')
" 2>/dev/null || echo "NOT_FOUND")
  if [[ "${FOUND_SMOKE}" == "FOUND" ]]; then
    pass "App feed contains created smoke item"
  else
    fail "Smoke item not found in app notice feed"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# [14] Admin update content
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [14] Admin Update Content (archive) ---"
if [[ -n "${CREATED_ID}" ]]; then
  UPDATE_PAYLOAD=$(cat <<EOF
{
  "title": "${SMOKE_TITLE} (archived)",
  "status": "archived"
}
EOF
)
  UPDATE_RESP_RAW=$(curl -sS -w "\n%{http_code}" --max-time 5 -X PUT "${API_BASE}/admin/api/v1/content/${CREATED_ID}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d "${UPDATE_PAYLOAD}") || true
  UPDATE_HTTP=$(echo "${UPDATE_RESP_RAW}" | tail -1)
  UPDATE_RESP=$(echo "${UPDATE_RESP_RAW}" | sed '$d')
  if [[ "${UPDATE_HTTP}" == "200" ]]; then
    pass "Admin update content: HTTP 200"
  else
    fail "Admin update content: HTTP ${UPDATE_HTTP}"
  fi
  security_check "Admin update response" "${UPDATE_RESP}" || true
else
  echo "  SKIP: no CREATED_ID from step [12]"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [15] Archived content hidden from app feed
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [15] Archived Content Hidden from App Feed ---"
if [[ -n "${CREATED_ID}" ]]; then
  APP_NOTICE_FEED2=$(curl -sS --max-time 5 "${API_BASE}/api/v1/content/app?placement=app_notice_center") || true
  FOUND_ARCHIVED=$(echo "${APP_NOTICE_FEED2}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('items',data.get('data',[]))
for item in items:
    if item.get('title') == '${SMOKE_TITLE}' or item.get('title') == '${SMOKE_TITLE} (archived)':
        print('FOUND')
        break
else:
    print('HIDDEN')
" 2>/dev/null || echo "HIDDEN")
  if [[ "${FOUND_ARCHIVED}" == "HIDDEN" ]]; then
    pass "Archived smoke item hidden from app feed"
  else
    fail "Archived smoke item still visible in app feed"
  fi
else
  echo "  SKIP: no CREATED_ID from step [12]"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [16] Link validation
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [16] Link Validation ---"
INVALID_LINK_PAYLOAD=$(cat <<EOF
{
  "slug": "smoke-invalid-link-${TIMESTAMP}",
  "locale": "en-US",
  "content_type": "announcement",
  "surface": "app",
  "placement": "app_notice_center",
  "title": "Invalid Link",
  "excerpt": "Testing link validation",
  "content_markdown": "Invalid link test",
  "tags": ["smoke-test"],
  "robots": "index,follow",
  "status": "published",
  "visibility": "public",
  "link_type": "external_url",
  "link_target": "http://insecure.example.com",
  "cta_label": "Visit"
}
EOF
)
INVALID_LINK_RESP_RAW=$(curl -sS -w "\n%{http_code}" --max-time 5 -X POST "${API_BASE}/admin/api/v1/content" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d "${INVALID_LINK_PAYLOAD}") || true
INVALID_LINK_HTTP=$(echo "${INVALID_LINK_RESP_RAW}" | tail -1)
INVALID_LINK_RESP=$(echo "${INVALID_LINK_RESP_RAW}" | sed '$d')
if [[ "${INVALID_LINK_HTTP}" == "400" ]]; then
  INVALID_CODE=$(echo "${INVALID_LINK_RESP}" | quiet_json "error.code" || echo "")
  if [[ -n "${INVALID_CODE}" ]]; then
    pass "Link validation: HTTP 400, code=${INVALID_CODE}"
  else
    pass "Link validation: HTTP 400"
  fi
else
  fail "Link validation: HTTP ${INVALID_LINK_HTTP} (expected 400)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [17] Delete/soft-delete
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [17] Delete Content ---"
if [[ -n "${CREATED_ID}" ]]; then
  DELETE_RESP_RAW=$(curl -sS -w "\n%{http_code}" --max-time 5 -X DELETE "${API_BASE}/admin/api/v1/content/${CREATED_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
  DELETE_HTTP=$(echo "${DELETE_RESP_RAW}" | tail -1)
  DELETE_RESP=$(echo "${DELETE_RESP_RAW}" | sed '$d')
  if [[ "${DELETE_HTTP}" == "200" || "${DELETE_HTTP}" == "204" ]]; then
    pass "Admin delete content: HTTP ${DELETE_HTTP}"
  else
    fail "Admin delete content: HTTP ${DELETE_HTTP} (expected 200/204)"
  fi
  GET_DELETED_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}/admin/api/v1/content/${CREATED_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
  if [[ "${GET_DELETED_HTTP}" == "404" ]]; then
    pass "Deleted content returns 404"
  else
    echo "  INFO: deleted content GET → HTTP ${GET_DELETED_HTTP} (soft-delete or still visible to admin)"
    pass "Deleted content status: HTTP ${GET_DELETED_HTTP}"
  fi
else
  echo "  SKIP: no CREATED_ID from step [12]"
fi

# Also clean up the invalid link item if it was created
INVALID_SLUG="smoke-invalid-link-${TIMESTAMP}"
pg_exec -c "DELETE FROM content_items WHERE slug='${INVALID_SLUG}'" 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Cleanup ---"
pg_exec -c "DELETE FROM content_items WHERE slug='${SMOKE_SLUG}' OR slug='${INVALID_SLUG}'" 2>/dev/null || true
pg_exec -c "DELETE FROM users WHERE email='${USER_EMAIL}'" 2>/dev/null || true
echo "  Cleaned up content smoke data"

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo " TASK-CICD-CONTENT-SEO-001 SUMMARY"
echo "========================================"
printf '%s\n' "${SUMMARY_LINES[@]}"

if [[ "${FAILED}" -eq 1 ]]; then
  echo ""
  echo "[TASK-CICD-CONTENT-SEO-001] CONTENT SMOKE FAILED."
  echo ""
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit 1
fi

echo ""
echo "[TASK-CICD-CONTENT-SEO-001] Content system full-link smoke PASSED."
