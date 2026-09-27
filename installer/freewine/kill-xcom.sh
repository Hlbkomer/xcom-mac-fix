#!/bin/bash
# Compatibility name: same as "stop.sh --game-only" (stops XCOM, keeps Steam). Use stop.sh to close everything.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stop.sh" --game-only
