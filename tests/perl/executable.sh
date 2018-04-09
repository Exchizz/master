#!/bin/bash

echo "Param1: $1";
echo "Param1: $2";
echo "Param1: $3";
echo "Starting node"
sleep 1
echo "Loading stuff";
sleep 1;
while sleep 1; do
	date > $1;
done
