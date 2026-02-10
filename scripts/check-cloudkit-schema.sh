#!/bin/bash
# Checks that all CKRecord field writes in Swift code are listed in cloudkit-schema.yml.
# Catches new fields that would fail on the shared database if not deployed.

set -euo pipefail

MANIFEST="cloudkit-schema.yml"
SOURCES="Softer"

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: $MANIFEST not found"
    exit 1
fi

# Extract declared field names from the manifest (lines like "  - fieldName  # comment")
declared_fields=$(sed -n 's/^[[:space:]]*-[[:space:]]*\([a-zA-Z_][a-zA-Z0-9_]*\).*/\1/p' "$MANIFEST" | sort -u)

# Extract field names written to CKRecords: record["fieldName"] =
# Uses sed to extract the field name from assignment patterns
written_fields=$(grep -rh 'record\["[a-zA-Z_]*"\] *=' "$SOURCES" --include='*.swift' \
    | sed 's/.*record\["\([a-zA-Z_][a-zA-Z0-9_]*\)"\].*/\1/' \
    | sort -u)

missing=()
for field in $written_fields; do
    if ! echo "$declared_fields" | grep -qx "$field"; then
        missing+=("$field")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: CKRecord fields written in code but not in $MANIFEST:"
    for field in "${missing[@]}"; do
        echo "  - $field"
        grep -rn "record\[\"$field\"\] =" "$SOURCES" --include='*.swift' | head -3 | sed 's/^/    /'
    done
    echo ""
    echo "Add these fields to $MANIFEST and deploy the schema in CloudKit Console."
    echo "The shared database enforces the deployed schema — missing fields break shared rooms."
    exit 1
fi

echo "OK: All $(echo "$written_fields" | wc -l | tr -d ' ') CKRecord fields are declared in $MANIFEST"
