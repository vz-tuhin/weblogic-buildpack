#!/bin/bash

TARGET_DIR=$(dirname $0)

#Kick off the monitorAgents script in background that will then kick off the individual agents and also monitor them continuously
$TARGET_DIR/monitorAgents.sh &