#!/usr/bin/env bash
# TASK-CICD-REVIEW-PACKET-SCHEMA-001
#
# Validates a Cursor Worker review packet or completion evidence JSON
# against its JSON Schema.
#
# Usage:
#   bash scripts/validate-review-packet.sh <packet-file> [--schema <schema-file>]
#
# Without --schema, auto-detects:
#   - review-packet-schema-v1.json for review packets
#   - completion-evidence-schema-v1.json for completion evidence
#
# Exit codes:
#   0  = all validations pass
#   1  = validation failure(s)
#   2  = usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="${SCRIPT_DIR}/schemas"

usage() {
  cat <<EOF
Usage: bash ${0##*/} <packet-file> [--schema <schema-file>]

Validates a Cursor Worker review packet or completion evidence JSON
against its JSON Schema.

Options:
  --schema <file>   Explicit schema file path. Auto-detected if omitted.
  --help, -h        Show this help.

Auto-detection:
  - If packet has "review_packet_version" key, schema is
    review-packet-schema-v1.json
  - If packet has "evidence_version" key, schema is
    completion-evidence-schema-v1.json
EOF
  exit 2
}

PACKET_FILE=""
SCHEMA_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --schema)
      SCHEMA_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      ;;
    *)
      if [[ -z "${PACKET_FILE}" ]]; then
        PACKET_FILE="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage
      fi
      shift
      ;;
  esac
done

if [[ -z "${PACKET_FILE}" ]]; then
  echo "ERROR: <packet-file> is required." >&2
  usage
fi

if [[ ! -f "${PACKET_FILE}" ]]; then
  echo "ERROR: packet file not found: ${PACKET_FILE}" >&2
  exit 2
fi

# Auto-detect schema if not specified
if [[ -z "${SCHEMA_FILE}" ]]; then
  local_version="$(python3 -c "
import json, sys
try:
    with open('${PACKET_FILE}') as f:
        d = json.load(f)
    if 'review_packet_version' in d:
        print('review-packet-schema-v1.json')
    elif 'evidence_version' in d:
        print('completion-evidence-schema-v1.json')
    else:
        print('unknown')
except Exception as e:
    print(f'error: {e}')
" 2>/dev/null || echo 'unknown')"

  case "${local_version}" in
    review-packet-schema-v1.json|completion-evidence-schema-v1.json)
      SCHEMA_FILE="${SCHEMA_DIR}/${local_version}"
      ;;
    unknown|error*)
      echo "ERROR: Cannot auto-detect schema for ${PACKET_FILE}" >&2
      echo "Use --schema to specify the schema file." >&2
      exit 2
      ;;
  esac
fi

if [[ ! -f "${SCHEMA_FILE}" ]]; then
  echo "ERROR: schema file not found: ${SCHEMA_FILE}" >&2
  exit 2
fi

echo "=== Validate Review Packet ==="
echo "Packet: ${PACKET_FILE}"
echo "Schema: ${SCHEMA_FILE}"
echo ""

# Ensure check-jsonschema is available
if ! command -v check-jsonschema &>/dev/null; then
  echo "WARN: check-jsonschema not found. Trying python3 -m check_jsonschema ..."
  if python3 -m check_jsonschema --help &>/dev/null; then
    CMD=(python3 -m check_jsonschema)
  else
    echo "check-jsonschema not installed. Install with: pip3 install check-jsonschema"
    echo "Falling back to Python-based validation..."
    python3 -c "
import json, sys, os

def validate_via_draft7(instance, schema):
    \"\"\"Minimal JSON Schema draft-07 validator.\"\"\"
    errors = []
    def _validate(inst, sch, path=''):
        # Enforce type mismatch: if type is specified and inst is not the
        # expected type (accounting for Python bool being a subclass of int),
        # record an error immediately.
        expected = sch.get('type')
        if expected is not None:
            if expected == 'array' and not isinstance(inst, list):
                errors.append(f\"{path}: type mismatch: expected array, got \" + type(inst).__name__)
                return
            if expected == 'object' and not isinstance(inst, dict):
                errors.append(f\"{path}: type mismatch: expected object, got \" + type(inst).__name__)
                return
            if expected == 'string' and not isinstance(inst, str):
                errors.append(f\"{path}: type mismatch: expected string, got \" + type(inst).__name__)
                return
            if expected == 'integer' and (not isinstance(inst, int) or isinstance(inst, bool)):
                errors.append(f\"{path}: type mismatch: expected integer, got \" + type(inst).__name__)
                return
            if expected == 'boolean' and not isinstance(inst, bool):
                errors.append(f\"{path}: type mismatch: expected boolean, got \" + type(inst).__name__)
                return
        if isinstance(inst, dict):
            # required check
            for req in sch.get('required', []):
                if req not in inst:
                    errors.append(f\"{path}: missing required field '{req}'\")
            # additionalProperties
            if sch.get('additionalProperties') == False:
                allowed = set(sch.get('properties', {}).keys())
                for k in inst:
                    if k not in allowed:
                        errors.append(f\"{path}: additional property '{k}' not allowed\")
            # properties
            for prop, prop_schema in sch.get('properties', {}).items():
                if prop in inst:
                    _validate(inst[prop], prop_schema, f\"{path}.{prop}\")
        elif sch.get('type') == 'array' and isinstance(inst, list):
            if 'minItems' in sch and len(inst) < sch['minItems']:
                errors.append(f\"{path}: minItems {sch['minItems']}, got {len(inst)}\")
            if 'uniqueItems' in sch and sch['uniqueItems']:
                seen = set()
                dupes = [x for x in inst if x in seen or seen.add(x)]
                # uniqueItems only meaningful for primitives in this fallback
            for i, item in enumerate(inst):
                _validate(item, sch.get('items', {}), f'{path}[{i}]')
        elif sch.get('type') == 'string' and isinstance(inst, str):
            if sch.get('minLength') is not None and len(inst) < sch['minLength']:
                errors.append(f\"{path}: minLength {sch['minLength']}, got {len(inst)}\")
            if 'pattern' in sch:
                import re
                if not re.match(sch['pattern'], inst):
                    errors.append(f\"{path}: pattern '{sch['pattern']}' not matched by '{inst}'\")
            if 'format' in sch and sch['format'] == 'date-time':
                import re
                if not re.match(r'^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$', inst) and \
                   not re.match(r'^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}[+-]\\d{2}:\\d{2}$', inst):
                    errors.append(f\"{path}: not a valid date-time format: '{inst}'\")
        elif sch.get('type') == 'integer' and isinstance(inst, int):
            if 'minimum' in sch and inst < sch['minimum']:
                errors.append(f\"{path}: minimum {sch['minimum']}, got {inst}\")
            if 'maximum' in sch and inst > sch['maximum']:
                errors.append(f\"{path}: maximum {sch['maximum']}, got {inst}\")
        elif sch.get('type') == 'boolean' and isinstance(inst, bool):
            if 'const' in sch and inst != sch['const']:
                errors.append(f\"{path}: const {sch['const']}, got {inst}\")
        elif 'enum' in sch:
            if inst not in sch['enum']:
                errors.append(f\"{path}: not in enum {sch['enum']}, got {inst!r}\")
        elif 'const' in sch:
            if inst != sch['const']:
                errors.append(f\"{path}: const {sch['const']}, got {inst!r}\")
    _validate(instance, schema)
    return errors

with open('${PACKET_FILE}') as f:
    instance = json.load(f)
with open('${SCHEMA_FILE}') as f:
    schema = json.load(f)

errors = validate_via_draft7(instance, schema)
if errors:
    print('VALIDATION FAILED:')
    for e in errors:
        print(f'  - {e}')
    sys.exit(1)
else:
    print('VALIDATION PASS')
" 2>&1
    rc=$?
    exit $rc
  fi
else
  CMD=(check-jsonschema)
fi

# Run check-jsonschema
"${CMD[@]}" --schemafile "${SCHEMA_FILE}" "${PACKET_FILE}"
