#!/bin/bash

# Store arguments in a special array
MD_PIPE=$SUB_METADATAPIPE;
DATA_PIPE=$SUB_DATAPIPE;

echo "Starting node consumer"
echo "Loading stuff consumer";
while true; do
	echo "Waiting for data on pipe: $MD_PIPE...";
	if read line <$MD_PIPE; then
		echo $line | jq . | tee >> /tmp/nonessential
	else
		echo "running consumer";
	fi;
done
