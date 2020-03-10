#!/bin/bash

# Usage:
# To check if new changes to the layer cause changes to any snapshots:
#   BUILD_LAYERS=true DD_API_KEY=XXXX aws-vault exec sandbox-account-admin -- ./scripts/run_integration_tests
# To regenerate snapshots:
#   UPDATE_SNAPSHOTS=true DD_API_KEY=XXXX aws-vault exec sandbox-account-admin -- ./scripts/run_integration_tests

set -e

# These values need to be in sync with serverless.yml, where there needs to be a function
# defined for every handler_runtime combination
LAMBDA_HANDLERS=("async-metrics" "sync-metrics" "http-requests")
RUNTIMES=("python27" "python36" "python37" "python38")

LOGS_WAIT_SECONDS=20

script_path=${BASH_SOURCE[0]}
scripts_dir=$(dirname $script_path)
repo_dir=$(dirname $scripts_dir)
integration_tests_dir="$repo_dir/tests/integration"

script_start_time=$(date --iso-8601=seconds)

mismatch_found=false

if [ -z "$DD_API_KEY" ]; then
    echo "No DD_API_KEY env var set, exiting"
    exit 1
fi

if [ -n "$UPDATE_SNAPSHOTS" ]; then
    echo "Overwriting snapshots in this execution"
fi

if [ -n "$BUILD_LAYERS" ]; then
    echo "Building layers that will be deployed with our test functions"
    source $scripts_dir/build_layers.sh
else
    echo "Not building layers, ensure they've already been built or re-run with 'REBUILD_LAYERS=true ./scripts/run_integration_tests.sh'"
fi

cd $integration_tests_dir
input_event_files=$(ls ./input_events)
# Sort event files by name so that snapshots stay consistent
input_event_files=($(for file_name in ${input_event_files[@]}; do echo $file_name; done | sort))

echo "Deploying functions"
serverless deploy

echo "Invoking functions"
set +e # Don't exit this script if an invocation fails or there's a diff
for handler_name in "${LAMBDA_HANDLERS[@]}"; do
    for runtime in "${RUNTIMES[@]}"; do
        function_name="${handler_name}_${runtime}"
        # Invoke function once for each input event
        for input_event_file in "${input_event_files[@]}"; do
            # Get event name without trailing ".json" so we can build the snapshot file name
            input_event_name=$(echo "$input_event_file" | sed "s/.json//")
            # Return value snapshot file format is snapshots/return_values/{handler}_{runtime}_{input-event}
            snapshot_path="./snapshots/return_values/${function_name}_${input_event_name}.json"

            return_value=$(serverless invoke -f $function_name --path "./input_events/$input_event_file")

            if [ ! -f $snapshot_path ]; then
                # If the snapshot file doesn't exist yet, we create it
                echo "Writing return value to $snapshot_path because no snapshot exists yet"
                echo "$return_value" >$snapshot_path
            elif [ -n "$UPDATE_SNAPSHOTS" ]; then
                # If $UPDATE_SNAPSHOTS is set to true, write the new logs over the current snapshot
                echo "Overwriting return value snapshot for $snapshot_path"
                echo "$return_value" >$snapshot_path
            else
                # Compare new return value to snapshot
                diff_output=$(echo "$return_value" | diff - $snapshot_path)
                if [ $? -eq 1 ]; then
                    echo "Failed: Return value for $function_name does not match snapshot:"
                    echo "$diff_output"
                    mismatch_found=true
                else
                    echo "Ok: Return value for $function_name with $input_event_name event matches snapshot"
                fi
            fi
        done

    done

done
set -e

echo "Sleeping $LOGS_WAIT_SECONDS seconds to wait for logs to appear in CloudWatch..."
sleep $LOGS_WAIT_SECONDS

echo "Fetching logs for invocations and comparing to snapshots"
for handler_name in "${LAMBDA_HANDLERS[@]}"; do
    for runtime in "${RUNTIMES[@]}"; do
        function_name="${handler_name}_${runtime}"
        function_snapshot_path="./snapshots/logs/$function_name.log"

        # Fetch logs with serverless cli
        raw_logs=$(serverless logs -f $function_name --startTime $script_start_time)

        # Replace invocation-specific data like timestamps and IDs with XXXX to normalize logs across executions
        logs=$(
            echo "$raw_logs" |
                # Filter serverless cli errors
                sed '/Serverless: Recoverable error occurred/d' |
                # Remove blank lines
                sed '/^$/d' |
                # Normalize Lambda runtime report logs
                sed -E 's/(RequestId|TraceId|SegmentId|Duration|Memory Used|"e"): [a-z0-9\.\-]+/\1: XXXX/g' |
                # Normalize DD APM headers
                sed -E "s/(x-datadog-parent-id:|x-datadog-trace-id:)[0-9]+/\1XXXX/g" |
                # Normalize timestamps in datapoints POSTed to DD
                sed -E 's/"points": \[\[[0-9\.]+,/"points": \[\[XXXX,/g' |
                # Strip API key from logged requests
                sed -E "s/(api_key=|'api_key': ')[a-z0-9\.\-]+/\1XXXX/g"
        )

        if [ ! -f $function_snapshot_path ]; then
            # If no snapshot file exists yet, we create one
            echo "Writing logs to $function_snapshot_path because no snapshot exists yet"
            echo "$logs" >$function_snapshot_path
        elif [ -n "$UPDATE_SNAPSHOTS" ]; then
            # If $UPDATE_SNAPSHOTS is set to true write the new logs over the current snapshot
            echo "Overwriting log snapshot for $function_snapshot_path"
            echo "$logs" >$function_snapshot_path
        else
            # Compare new logs to snapshots
            set +e # Don't exit this script if there is a diff
            diff_output=$(echo "$logs" | diff - $function_snapshot_path)
            if [ $? -eq 1 ]; then
                echo "Failed: Mismatch found between new $function_name logs (first) and snapshot (second):"
                echo "$diff_output"
                mismatch_found=true
            else
                echo "Ok: New logs for $function_name match snapshot"
            fi
            set -e
        fi
    done
done

if [ "$mismatch_found" = true ]; then
    echo "FAILURE: A mismatch between new data and a snapshot was found and printed above."
    echo "If the change is expected, generate new snapshots by running 'UPDATE_SNAPSHOTS=true ./scripts/run_integration_tests.sh'"
    exit 1
fi

if [ -n "$UPDATE_SNAPSHOTS" ]; then
    echo "SUCCESS: Wrote new snapshots for all functions"
    exit 0
fi

echo "SUCCESS: No difference found between new logs and snapshots"