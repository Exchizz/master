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
sleep 1
echo "Loading stuff consumer";
sleep 1;

while true; do
	if read line <$1; then
		echo $line
	else
		echo "running consumer";
	fi;
done
