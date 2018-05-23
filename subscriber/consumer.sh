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

echo "Starting node consumer"
echo "Loading stuff consumer";
while true; do
	echo "Waiting for data on pipe: $2...";
	if read line <$2; then
		echo $line | jq . | tee >> /tmp/nonessential
	else
		echo "running consumer";
	fi;
done
