#!/bin/sh

TARGET_DIR=$(dirname $0)

# Dont kick off right away
# Ruby might get picked as the process to watch rather than java or node-js, as the server is yet to start....
WAIT_INTERVAL_BEFORE_KICKOFF=30

$TARGET_DIR/dumpHeapAgent.sh   $WAIT_INTERVAL_BEFORE_KICKOFF  2>&1  >  $TARGET_DIR/dumpHeapAgent.log   &
$TARGET_DIR/dumpStatsAgent.sh  $WAIT_INTERVAL_BEFORE_KICKOFF  2>&1  >  $TARGET_DIR/dumpStatsAgent.log  &
$TARGET_DIR/dumpThreadAgent.sh $WAIT_INTERVAL_BEFORE_KICKOFF  2>&1  >  $TARGET_DIR/dumpThreadAgent.log &