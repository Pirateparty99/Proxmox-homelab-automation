#!/bin/bash

DBPW=$(timeout 20 oc get secret kasm-workspaces-secrets -n kasm-workspaces -o jsonpath='{.data.db-password}' 2>/dev/null | base64 -d)
echo "=== unlock ==="
timeout 60 oc exec -n kasm-workspaces kasm-workspaces-db-1-19-0-0 -- env PGPASSWORD="$DBPW" psql -U kasmapp -d kasm -t -A \
  -c "update users set locked=false, failed_pw_attempts=0 where username='admin@kasm.local'" 2>/dev/null | sed 's/^/  /'
