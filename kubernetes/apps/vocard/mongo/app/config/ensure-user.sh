#!/bin/sh
# Ensure the MongoDB application user exists and matches the current
# MONGODB_PASSWORD from the ESO-owned Secret.
#
# Why this exists: the image entrypoint provisions this user ONLY when
# /data/db is empty. A local-path PVC reclaim can leave a dirty volume behind,
# and any later wipe of the volume drops the user again — leaving the bot
# crash-looping on UserNotFound / AuthenticationFailed until someone runs
# mongosh by hand. As a postStart hook this runs on EVERY container start, so
# the credential self-heals.
#
# The password is read from the container's own env and expanded inside the
# pod, so it never appears in a command line or in a transcript.
set -eu

echo "ensure-user: waiting for mongod to accept connections"
ready=0
i=0
while [ "$i" -lt 60 ]; do
  if mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 2
done

if [ "$ready" -ne 1 ]; then
  echo "ensure-user: mongod not reachable after 120s" >&2
  exit 1
fi

# Idempotent: branch on whether the user survived, since a re-provisioned
# volume has none and updateUser then fails with "User <u>@<db> not found".
# Values come from process.env so nothing is interpolated into the JS source.
mongosh "$MONGODB_DB" --quiet --eval '
  const user = process.env.MONGODB_USERNAME;
  const pwd = process.env.MONGODB_PASSWORD;
  const dbName = process.env.MONGODB_DB;
  const roles = [{ role: "root", db: "admin" }];
  if (db.getUser(user) !== null) {
    db.updateUser(user, { pwd: pwd, roles: roles });
    print("ensure-user: updated " + user + "@" + dbName);
  } else {
    db.createUser({ user: user, pwd: pwd, roles: roles });
    print("ensure-user: created " + user + "@" + dbName);
  }
'

echo "ensure-user: verifying authenticated login"
mongosh "$MONGODB_DB" -u "$MONGODB_USERNAME" -p "$MONGODB_PASSWORD" \
  --quiet --eval 'print("ensure-user: auth OK")'
