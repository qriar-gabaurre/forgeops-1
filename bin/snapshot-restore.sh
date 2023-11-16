#!/usr/bin/env bash
# Script to restore a volume snapshot to a DS statefulset.
#set -oe pipefail

# Grab our starting dir
start_dir=$(pwd)
# Figure out the dir we live in
SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
# Bring in our standard functions
source $SCRIPT_DIR/stdlib.sh
cd $start_dir

usage() {
    exit_code=$1
    err=$2
    prog=$(basename $0)
    cat <<EOM
Usage: $prog [OPTIONS] ACTION RESTORE_TARGET

Restore a DS StatefulSet from a VolumeSnapshot. When doing a full restore, the
StatefulSet will be scaled down to 0 pods, the existing PVCs will be recreated
with the snapshot as the data source. This operation requires downtime.

The selective restore creates a new PVC, StatefulSet, and Service that creates a
single new DS pod. This allows you to selectively export and import data as
needed. After restoring all needed data, the clean action will clean up the
temporary resources. You need to use --dir to specify the restore dir when using
clean.

NOTES:
  * Valid restore actions: ${VALID_ACTIONS[@]}
  * Valid restore targets: ${VALID_TARGETS[@]}
  * Only one action and target allowed per run
  * Only one active selective restore per restore target
  * If a namespace isn't supplied, kubectl will rely on context and environment
  * While -d is required for clean, it can be used with any action

  OPTIONS:
    -h|--help                    : display usage and exit
    --debug                      : enable debugging output
    --dryrun                     : do a dry run
    -v|--verbose                 : be verbose
    -d|--dir /path/to/restore/   : path to dir to use for restore artifacts
    -n|--namespace NAMESPACE     : namespace to work in
    -s|--snapshot SNAPSHOT_NAME  : name of the snapshot to restore from
                                   (default: latest snapshot)

Requirements:
  * kubectl
  * jq

Examples:
  Full restore of latest snapshot on idrepo:
  $prog -n my-namespace full idrepo

  Full restore of specific snapshot on cts:
  $prog -s ds-idrepo-snapshot-20231003-0000 full cts

  Use a specific dir for restore artifacts:
  $prog -d /tmp/ds-restore -s ds-idrepo-snapshot-20231003-0000 full idrepo

  Selective restore of specific snapshot for idrepo:
  $prog -s ds-idrepo-snapshot-20231003-0000 selective idrepo

  Perform a selective restore with a user defined dir:
  $prog -d /tmp/ds-restore -s ds-idrepo-snapshot-20231003-0000 selective idrepo

  Clean up k8s resources from selective restore:
  $prog -d /tmp/ds-restore clean idrepo

EOM

  if [ ! -z "$err" ] ; then
    echo "ERROR: $err"
    echo
  fi

  exit $exit_code
}

# Use runOrPrint to execute kubectl, and apply the namespace
kube() {
  message "Starting kube()" "debug"

  runOrPrint "$K_CMD $* $NAMESPACE_OPT"

  message "Finishing kube()" "debug"
}

kubeExists() {
  message "Starting kubeExists()" "debug"

  local exit_code=1
  if $K_GET $1 $2 --no-headers > /dev/null 2>&1 ; then
    exit_code=0
  fi

  message "Finishing kubeExists()" "debug"
  return $exit_code
}

# Strip k8s metadata out of a json file
stripMetadata() {
  message "Starting stripMetadata()" "debug"

  local file=$1
  local new_file="${file}.new"
  local jq_filter=$(cat <<-END
    del(
      .metadata.annotations."autoscaling.alpha.kubernetes.io/conditions",
      .metadata.annotations."autoscaling.alpha.kubernetes.io/current-metrics",
      .metadata.annotations."control-plane.alpha.kubernetes.io/leader",
      .metadata.annotations."deployment.kubernetes.io/revision",
      .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
      .metadata.annotations."kubernetes.io/service-account.uid",
      .metadata.annotations."pv.kubernetes.io/bind-completed",
      .metadata.annotations."pv.kubernetes.io/bound-by-controller",
      .metadata.finalizers,
      .metadata.managedFields,
      .metadata.creationTimestamp,
      .metadata.generation,
      .metadata.resourceVersion,
      .metadata.selfLink,
      .metadata.uid,
      .spec.clusterIP,
      .spec.clusterIPs,
      .spec.dataSourceRef,
      .spec.progressDeadlineSeconds,
      .spec.revisionHistoryLimit,
      .spec.template.metadata.annotations."kubectl.kubernetes.io/restartedAt",
      .spec.template.metadata.creationTimestamp,
      .spec.volumeName,
      .spec.volumeMode,
      .status
    )
END)

  jq --exit-status --compact-output --monochrome-output --raw-output --sort-keys 2>/dev/null "$jq_filter" $file > $new_file
  mv $new_file $file

  message "Finishing stripMetadata()" "debug"
}

# Merge two json files together
mergeJson() {
  message "Starting mergeJson()" "debug"

  local file=$1
  local add_file=$2
  local new_file="$$_new.json"

  jq -s '.[0] * .[1]' $file $add_file > $new_file
  mv $new_file $file

  message "Finishing mergeJson()" "debug"
}

# Get the currently running service definition
getSvc() {
  message "Starting getSvc()" "debug"

  $K_GET svc ds-$TARGET -o json > $SVC_PATH
  stripMetadata $SVC_PATH

  message "Finishing getSvc()" "debug"
}

# Prep the service when doing a selective restore
prepSvc() {
  message "Starting prepSvc()" "debug"

  if [ "$ACTION" == "selective" ] ; then
    sed -i .bak -e "s/ds-$TARGET/ds-$TARGET-restore/" $SVC_PATH
  fi

  message "Finishing prepSvc()" "debug"
}

# Apply the SVC
applySvc() {
  message "Starting applySvc()" "debug"

  kube apply -f $SVC_PATH

  message "Finishing applySvc()" "debug"
}

# Get the currently running STS definition
getSts() {
  message "Starting getSts()" "debug"

  $K_GET sts ds-$TARGET -o json > $STS_PATH
  stripMetadata $STS_PATH

  message "Finishing getSts()" "debug"
}

# Prep the restore STS based on the restore type
prepSts() {
  message "Starting prepSts()" "debug"

  local replicas=0 # Assume full restore by default
  cp $STS_PATH $STS_RESTORE_PATH
  if [ "$ACTION" == "selective" ] ; then
    replicas=1
    sed -i .bak -e "s/ds-$TARGET/ds-$TARGET-restore/g" $STS_RESTORE_PATH
    createPvcAdd
    mergeJson $STS_RESTORE_PATH $PVC_ADD_FILE
  fi

  local add_file=$RESTORE_DIR/replicas.json
  cat > $add_file <<EOM
{
  "spec": {
    "replicas": $replicas
  }
}
EOM

  mergeJson $STS_RESTORE_PATH $add_file

  message "Finishing prepSts()" "debug"
}

# Apply the STS
applySts() {
  message "Starting applySts()" "debug"

  kube apply -f $STS_RESTORE_PATH

  message "Finishing applySts()" "debug"
}

# Restore the STS when doing a full restore
restoreSts() {
  message "Starting restoreSts()" "debug"

  kube apply -f $STS_PATH

  message "Finishing restoreSts()" "debug"
}

# Create a file to hold the snapshot to source from. Merged with another file
createPvcAdd() {
  message "Starting createPvcAdd()" "debug"

  local add_file="$RESTORE_DIR/pvc_snip.json"
  cat > $add_file << EOM
{
  "spec": {
    "dataSource": {
      "name": "$SNAPSHOT_NAME",
      "kind": "VolumeSnapshot",
      "apiGroup": "snapshot.storage.k8s.io"
    }
  }
}
EOM

  if [ "$ACTION" == "full" ] ; then
    mv $add_file $PVC_ADD_FILE
  elif [ "$ACTION" == "selective" ] ; then
    local vct_file="$RESTORE_DIR/vct.json"
    jq '.spec.volumeClaimTemplates[0]' $STS_RESTORE_PATH > $vct_file
    stripMetadata $vct_file
    mergeJson $vct_file $add_file
    echo '{"spec":{"volumeClaimTemplates":[]}}' | jq --argjson pvc_add "$(<$vct_file)" '.spec.volumeClaimTemplates = [$pvc_add]' > $PVC_ADD_FILE
  fi

  message "Finishing createPvcAdd()" "debug"
}

# Get our list of PVCs to work with when doing a full restore
getPvcs() {
  message "Starting getPvcs()" "debug"

  PVCS=$($K_GET pvc -l "app.kubernetes.io/instance=ds-${TARGET}" --no-headers=true -o custom-columns=NAME:.metadata.name)

  for pvc in $PVCS ; do
    local pvc_path="${RESTORE_DIR}/${pvc}.json"
    $K_GET pvc $pvc -o json > $pvc_path
    stripMetadata $pvc_path
  done

  message "Finishing getPvcs()" "debug"
}

# Prep our PVCs to be created from the snapshot
prepPvcs() {
  message "Starting prepPvcs()" "debug"

  createPvcAdd
  for pvc in $PVCS ; do
    local file="$RESTORE_DIR/${pvc}.json"
    mergeJson $file $PVC_ADD_FILE
  done

  message "Finishing prepPvcs()" "debug"
}

# Delete existing PVCs
deletePvcs() {
  message "Starting deletePvcs()" "debug"

  for pvc in $PVCS ; do
    kube delete pvc $pvc
  done

  message "finishing deletePvcs()" "debug"
}

# Create new PVCs
createPvcs() {
  message "Starting createPvcs()" "debug"

  for pvc in $PVCS ; do
    kube apply -f $RESTORE_DIR/${pvc}.json
  done

  message "Finishing createPvcs()" "debug"
}

# Defaults
DEBUG=false
DRYRUN=false
VERBOSE=false

ACTION=
NAMESPACE=
RESTORE_DIR=
SNAPSHOT_NAME=
TARGET=

VALID_ACTIONS=("full" "selective" "clean")
VALID_TARGETS=("idrepo" "cts")

while true; do
  case "$1" in
    -h|--help) usage 0 ;;
    --debug) DEBUG=true; shift ;;
    --dryrun) DRYRUN=true; shift ;;
    -v|--verbose) VERBOSE=true; shift ;;
    -d|--dir) RESTORE_DIR=$2; shift 2 ;;
    -n|--namespace) NAMESPACE=$2; shift 2 ;;
    -s|--snapshot) SNAPSHOT_NAME=$2; shift 2 ;;
    "") break ;;
    *) if [ -z "$ACTION" ] ; then
         ACTION=$1
         shift
       elif [ -z "$TARGET" ] ; then
         TARGET=$1
         shift
       else
         usage 1 "Unknown arg: $1"
       fi
       ;;
  esac
done

message "DEBUG=$DEBUG" "debug"
message "DRYRUN=$DRYRUN" "debug"
message "VERBOSE=$VERBOSE" "debug"

message "ACTION=$ACTION" "debug"
message "NAMESPACE=$NAMESPACE" "debug"
message "SNAPSHOT_NAME=$SNAPSHOT_NAME" "debug"
message "TARGET=$TARGET" "debug"

if [ -n "$ACTION" ] ; then
  if containsElement $ACTION ${VALID_ACTIONS[@]} ; then
    message "Restore type is valid: $ACTION" "debug"
  else
    usage 1 "Invalid restore type: $ACTION"
  fi

  if [ "$ACTION" == "clean" ] && [ -z $RESTORE_DIR ] ; then
    usage 1 "You must use -d/--dir with clean"
  fi
else
  usage 1 "An action is required. ( ${VALID_ACTIONS[*]} )"
fi

if [ -n "$TARGET" ] ; then
  if containsElement $TARGET ${VALID_TARGETS[@]} ; then
    message "Restore target is valid: $TARGET" "debug"
  else
    usage 1 "Invalid restore target: $TARGET"
  fi
else
  usage 1 "A target is required. ( ${VALID_TARGETS[*]} )"
fi

# Namespace string
if [ -z "$NAMESPACE" ] ; then
  NAMESPACE_OPT=""
else
  NAMESPACE_OPT="-n $NAMESPACE"
fi

# kubectl commands
K_CMD="$(type -P kubectl)"
K_GET="$K_CMD get $NAMESPACE_OPT"

JOB_LABEL="ds-${TARGET}-snapshot-job"
message "JOB_LABEL=$JOB_LABEL" "debug"

# Use latest snapshot if none given
if [ -z "$SNAPSHOT_NAME" ] ; then
  message "No snapshot name given to use for restore. Using latest." "debug"
  SNAPSHOT_NAME=$($K_GET volumesnapshot -l "app=$JOB_LABEL" | tail -1 | awk '{ print $1 }')
fi
message "SNAPSHOT_NAME=$SNAPSHOT_NAME" "debug"

if [ "$ACTION" == "selective" ] || [ "$ACTION" == "clean" ] ; then
  STS_RESTORE_NAME="ds-${TARGET}-restore"
fi

# Setup directory to hold files needed to do the restore
if [ -z "$RESTORE_DIR" ] && [ "$ACTION" == "clean" ]; then
  usage 1 "Must supply -d|--dir when doing a clean"
elif [ -z "$RESTORE_DIR" ] ; then
  TIMESTAMP=$(date -u "+%Y%m%dT%TZ")
  RESTORE_DIR=/tmp/snapshot-restore-${TARGET}.$TIMESTAMP
fi
message "RESTORE_DIR=$RESTORE_DIR" "debug"

if [ ! -d "$RESTORE_DIR" ] ; then
  mkdir -p $RESTORE_DIR
fi

PVC_ADD_FILE="$RESTORE_DIR/pvc_add.json"
STS_FILE="sts.json"
STS_PATH="$RESTORE_DIR/$STS_FILE"
STS_RESTORE_FILE="sts-restore.json"
STS_RESTORE_PATH="$RESTORE_DIR/$STS_RESTORE_FILE"
SVC_FILE="svc.json"
SVC_PATH="$RESTORE_DIR/$SVC_FILE"

case "$ACTION" in
  full)
    message "Requested restore type: full" "debug"
    getSts
    prepSts
    applySts
    getPvcs
    prepPvcs
    deletePvcs
    createPvcs
    restoreSts
    ;;

  selective)
    message "Requested restore type: selective" "debug"
    if kubeExists sts $STS_RESTORE_NAME ; then
      usage 1 "Only one selective restore can be active at a time"
    fi
    getSts
    prepSts
    applySts
    getSvc
    prepSvc
    applySvc
    ;;

  clean)
    message "Requested restore type: clean" "debug"
    kube delete svc $STS_RESTORE_NAME --ignore-not-found=true
    kube delete sts $STS_RESTORE_NAME --ignore-not-found=true
    kube delete pvc -l "app.kubernetes.io/instance=$STS_RESTORE_NAME" --ignore-not-found=true
    ;;
esac