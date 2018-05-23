#!/bin/bash

# store arguments in a special array 
args=("$@") 
# get number of elements 
ELEMENTS=${#args[@]} 
 
# echo each element in array  
# for loop 
for (( i=0;i<$ELEMENTS;i++)); do 
    echo "Param $i:${args[${i}]}"
done

echo "Starting node"
sleep 1
echo "Loading stuff";
sleep 1;
cat <>$1 &
cat <>$2 &
while sleep 1; do
	date > $1;
	cat metadata_example.json > $2	
#	date > $2
done
