#!/usr/bin/env bash
# gen-logs.sh — append realistic log lines to a file at an interval, so you can
# test your M1 tailer's "follow" behavior (and rotation).
#
# Usage:
#   ./gen-logs.sh [FILE] [INTERVAL_SECONDS]
# Examples:
#   ./gen-logs.sh app.log 1      # append one line per second to app.log
#   ./gen-logs.sh app.log 0.2    # 5 lines/second (stress your buffer)
#
# To test ROTATION while it runs, in another terminal:
#   mv app.log app.log.1 && touch app.log     # rename+recreate (inode changes)
# To test TRUNCATION:
#   : > app.log                                # empties the file
#
# Stop with Ctrl-C.

FILE="${1:-app.log}"
INTERVAL="${2:-1}"

LEVELS=("INFO" "INFO" "INFO" "INFO" "DEBUG" "WARN" "ERROR")   # weighted toward INFO
COMPONENTS=("http" "db" "cache" "auth" "payment" "ratelimit" "memory")

methods=("GET" "POST" "DELETE" "PUT")
paths=("/healthz" "/v1/orders" "/v1/products" "/v1/products/5567" "/v1/cart" "/v1/admin")
codes=("200" "200" "200" "201" "204" "401" "404" "500" "503")

rand() { echo $(( RANDOM % $1 )); }
pick() { local arr=("$@"); echo "${arr[$(rand ${#arr[@]})]}"; }

echo "Appending to '$FILE' every ${INTERVAL}s. Ctrl-C to stop."
while true; do
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  level="$(pick "${LEVELS[@]}")"
  comp="$(pick "${COMPONENTS[@]}")"

  case "$comp" in
    http)
      msg="$(pick "${methods[@]}") $(pick "${paths[@]}") $(pick "${codes[@]}") $(rand 80)ms" ;;
    db)
      msg="query took $(rand 900)ms pool_active=$(rand 20)/20" ;;
    cache)
      msg="cache $([ $(rand 2) -eq 0 ] && echo hit || echo miss) key=product:$(rand 9999)" ;;
    auth)
      msg="token check for user u_$(rand 9999)" ;;
    payment)
      msg="charge ch_$(rand 99999) amount=$(rand 200).99 currency=USD" ;;
    ratelimit)
      msg="client 203.0.113.$(rand 255) at $(rand 100)/100 req/min" ;;
    memory)
      msg="heap usage $(rand 100)% ($(rand 800)MB/800MB)" ;;
  esac

  printf '%s %-5s %-10s %s\n' "$ts" "$level" "$comp" "$msg" >> "$FILE"
  sleep "$INTERVAL"
done
