#!/bin/bash

set -ex

check_status() {
	retry_max=60
	retry_wait_sec=10
	retry=0

	protocol='http'
	host='127.0.0.1'
	port='6985'
	endpoint='wsman'
	expected_status=405

	while [[ $retry -lt $retry_max ]]; do
		set +e
		status=$(curl -sw '%{http_code}' --noproxy ${host} ${protocol}://${host}:${port}/${endpoint})
		set -e
		echo "Received status ${status}"
		if [[ $status -eq $expected_status ]]; then
			break
		fi
		let retry=retry+1
		if [[ $retry -eq $retry_max ]]; then
			echo "Reached max number of retries: ${retry_max}"
			exit 1
		else
			echo "Waiting ${retry_wait_sec} seconds for retry # ${retry}"
			sleep $retry_wait_sec
		fi
	done
	
}

check_status
echo "Success"
