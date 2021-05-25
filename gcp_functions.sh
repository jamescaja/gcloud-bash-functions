# ----------------------------------------------------------------------------------------------------------
# Initialization
# ----------------------------------------------------------------------------------------------------------
excludeProjectNames="hive-dataproc-poc,express-customer-cdh,'My First Project'"
maxCacheAge=300
clusterNodePollInterval=10
#describeFileDir=./run-state

# runDir=/apps/run-state/tools
# logDir=/apps/logs/tools/cloud
# tmpDir=/apps/temp/tools

runDir=/Users/jcarlisle/edmt_infra/run-state
logDir=/Users/jcarlisle/edmt_infra/logs
tmpDir=/Users/jcarlisle/edmt_infra/temp


describeFileDir=$runDir

describeOutputFormat=json
#describeOutputFormat=yaml


# ----------------------------------------------------------------------------------------------------------
# UTILITY functions
# ----------------------------------------------------------------------------------------------------------

describeCacheExpired () {

    # Build
    if [ $# -eq 1 ]; then
        local describeFile=$1
    else
        return
    fi

    # Calculate cache file age
    now=$(date +%s)
    fileModTime=$(stat --printf "%Y" $describeFile)

    timeDiff=$(( $now - $fileModTime ))

    # Return cache expiration status
    if [[ $timeDiff -gt $maxCacheAge ]]; then
        echo 1
    else
        echo 0
    fi

}

validateRequiredGCVersion () {

    # Build
    if [ $# -eq 1 ]; then
        local requiredVersion=$1
    else
        return
    fi

    case "$(getCurrentGCVersion)" in 
        ${requiredVersion})
            echo 1 ;;
        *)
            echo 0 ;;
    esac

}

validateObject () {
    # Build
    if [ $# -eq 3 ]; then
        local objectType=$1
        local objectName=$2
        local projectName=$3
    else
        # log invalid parameter call and return
        echo "failed parameter check, exiting..."
        return
    fi

}

describeObject () {

    # Build
    if [ $# -eq 5 ]; then
        local objectClass=$1
        local objectType=$2
        local objectName=$3
        local projectName=$4
        local forceFlag=$5
    else
        # log invalid parameter call and return
        echo "failed parameter check, exiting..."
        return
    fi

    # Defaults - Override if needed
    local refreshCache=0        # No refresh
    local releaseLevel=         # Use core release
    local scopeType="project"   # [project, organization]
    local optionType="base"     # [base, region, zone]

    case "$objectClass" in 

        "ai-platform")

            case "$objectType" in

                "models")               objectLabel="AI-MODEL" ;;

                *) echo "Type [ $objectType ] not currently supported."; return ;;
            esac
            ;;

        "compute")

            case "$objectType" in

                "disks")                objectLabel="DISK";         optionType="zone" ;;
                "instances")            objectLabel="INSTANCE" ;;
                "machine-types")        objectLabel="MACHINE-TYPE"; optionType="zone" ;;
                "snapshots")            objectLabel="SNAPSHOT" ;;
                "vpn-gateways")         objectLabel="VPN-GATEWAY";  optionType="region"; releaseLevel="beta" ;;
                "vpn-tunnels")          objectLabel="VPN-TUNNEL";   optionType="region" ;;

                *) echo "Type [ $objectType ] not currently supported."; return ;;
            esac
            ;;

        "config")

            scopeType="organization"
            case "$objectType" in

                "configurations")       objectLabel="CONFIG" ;;

                *) echo "Type [ $objectType ] not currently supported."; return ;;

            esac
            ;;

        "dataproc")

            case "$objectType" in

                "autoscaling-policies") objectLabel="AUTOSCALE";    optionType="region";    releaseLevel="beta" ;;
                "clusters")             objectLabel="CLUSTER";      optionType="region" ;;

                *) echo "Type [ $objectType ] not currently supported."; return ;;

            esac
            ;;

        "iam")

            case "$objectType" in

                "roles")                objectLabel="ROLE"            ;;
                "service-accounts")     objectLabel="SERVICE-ACCOUNT" ;;

                *) echo "Type [ $objectType ] not currently supported."; return ;;

            esac
            ;;

        "sql")

            case "$objectType" in

                "instances")            objectLabel="SQL-INSTANCE" ;;

                *) echo "Type [ $objectType ] not currently supported."; return ;;

            esac
            ;;

        *) echo "Class [ $objectClass ] not currently supported."; return ;;

    esac


    # Build cache file spec
    local describeFile=$describeFileDir/$objectLabel"_"$objectName"."$describeOutputFormat

    # Figure out if the cache file needs to be refreshed
    if [ ! -f "$describeFile" ] || [ $forceFlag -eq 1 ]; then
        # File doesnt exist or force refresh requested
        refreshCache=1
    else
        # Check cache expiration - set flag accordingly
        refreshCache=$(describeCacheExpired $describeFile)
    fi


    # If cache needs refreshed, rebuild the file
    if [ $refreshCache -eq 1 ]; then

        # Build base command string
        local sdkCommand="gcloud $releaseLevel $objectClass $objectType describe"

        # Build full command string for this object
        case "$scopeType" in 

            "organization")

                gcloudCmd="$sdkCommand $objectName --format=$describeOutputFormat > $describeFile"
                ;;

            "project")

                case "$optionType" in

                    "base") 
                        gcloudCmd="$sdkCommand $objectName --project=$projectName --format=$describeOutputFormat > $describeFile"
                        ;;

                    "region") 
                        local _region=$(getDefaultRegion)
                        gcloudCmd="$sdkCommand $objectName --project=$projectName --format=$describeOutputFormat --region=$_region  > $describeFile"
                        ;;

                    "zone") 
                        local _zone=$(getDefaultZone)
                        gcloudCmd="$sdkCommand $objectName --project=$projectName --format=$describeOutputFormat --zone=$_zone > $describeFile"
                        ;;

                esac

        esac

        # Execute full command string to refresh cache file
        eval $gcloudCmd
    fi

    # Display the cache file
    cat $describeFile

}

listProjects () {

    # Build
    if [ $# -eq 0 ]; then # use the default
        local pcolumn="project_id"
    else                  # override the default
        local pcolumn=$1
    fi

    gcloudCmd="gcloud projects list --format=\"value("$pcolumn")\" --filter=\"NOT name = ("$excludeProjectNames")\" --sort-by="$pcolumn" --quiet"

    # Execute
    eval $gcloudCmd

}



# ----------------------------------------------------------------------------------------------------------
# DATAPROC functions
# ----------------------------------------------------------------------------------------------------------

clusterIsUp () {

    # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=1

    case "$(describeObject dataproc clusters $clusterName $projectName $forceRefresh | jq -r '.status.state')" in 
        "RUNNING")
            echo 1 ;;
        *)
            echo 0 ;;
    esac

}

waitForNodeStartup () {

    # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

     local anyNodeIsDown=1

     while [ $anyNodeIsDown -eq 1 ]; do

         nodeIsDown=0  # Assume nodes are all up.  Update flag below if one is found.

         # Check each node for up/down status.
         for clusterNode in $(getDataprocNodes $clusterName $projectName); 
         do
             case "$(instanceIsDown $clusterNode $projectName)" in
                 1)  nodeIsDown=1; break 1  # Found a downed node, so stop looking for others.
                     ;;
             esac

         done

         anyNodeIsDown=$nodeIsDown

         sleep 5

     done

    echo 1
}

waitForNodeShutdown () {

    # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi


    local anyNodeIsUp=1
    while [ $anyNodeIsUp -eq 1 ]; do

        nodeIsUp=0  # Assume nodes are all down.  Update flag below if one is found.

        # Check each node for up/down status.
        for clusterNode in $(getDataprocNodes $clusterName $projectName); 
        do
            case "$(instanceIsUp $clusterNode $projectName)" in
                1)  nodeIsUp=1; break 1  # Found a running node, so stop looking for others.
                    ;;
            esac

        done

        anyNodeIsUp=$nodeIsUp


        sleep 5

    done

    echo 1
}

getDataprocNodes () {

    # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject dataproc clusters $clusterName $projectName $forceRefresh | jq -r '.config.masterConfig.instanceNames[], .config.workerConfig.instanceNames[]'

}

getDataprocMasterNode () {

    # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject dataproc clusters $clusterName $projectName $forceRefresh | jq -r '.config.masterConfig.instanceNames[]'

}

getDataprocWorkerNodes () {

     # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject dataproc clusters $clusterName $projectName $forceRefresh | jq -r '.config.workerConfig.instanceNames[]'

}

getDataprocNetworkTags () {

    # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject dataproc clusters $clusterName $projectName $forceRefresh | jq -r '.config.gceClusterConfig.tags[]'

}

getDataprocServiceAccount () {

    # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject dataproc clusters $clusterName $projectName $forceRefresh | jq -r '.config.gceClusterConfig.serviceAccount'

}

getDataprocInitScript () {

    # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject dataproc clusters $clusterName $projectName $forceRefresh | jq -r '.config.initializationActions[].executableFile'

}

getDataprocNodeMgrResourceMemory () {

     # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject dataproc clusters $clusterName $projectName $forceRefresh | jq -r '.config.softwareConfig.properties."yarn:yarn.nodemanager.resource.memory-mb"'

}

getDataprocSparkExecutorCores () {

     # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject dataproc clusters $clusterName $projectName $forceRefresh | jq -r '.config.softwareConfig.properties."spark:spark.executor.cores"'

}

getDataprocSparkExecutorInstances () {

     # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject dataproc clusters $clusterName $projectName $forceRefresh | jq -r '.config.softwareConfig.properties."spark:spark.executor.instances"'

}

getDataprocSparkExecutorMemory () {

     # Build
    if [ $# -eq 2 ]; then
        local clusterName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject dataproc clusters $clusterName $projectName $forceRefresh | jq -r '.config.softwareConfig.properties."spark:spark.executor.memory"'

}

# ----------------------------------------------------------------------------------------------------------
# CLOUD SQL functions
# ----------------------------------------------------------------------------------------------------------

sqlIsUp () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=1

    case "$(describeObject sql instances $instanceName $projectName $forceRefresh | jq -r '.state')" in 
        "RUNNABLE")
            echo 1 ;;
        *)
            echo 0 ;;
    esac

}

sqlIsPrimary () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=1

    case "$(describeObject sql instances $instanceName $projectName $forceRefresh | jq -r '.instanceType')" in 
        "CLOUD_SQL_INSTANCE")
            echo 1 ;;
        *)
            echo 0 ;;
    esac

}

sqlIsReplica () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=1

    case "$(describeObject sql instances $instanceName $projectName $forceRefresh | jq -r '.instanceType')" in 
        "READ_REPLICA_INSTANCE")
            echo 1 ;;
        *)
            echo 0 ;;
    esac

}

sqlHAEnabled () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=1

    case "$(describeObject sql instances $instanceName $projectName $forceRefresh | jq -r '.availabilityType')" in 
        "REGIONAL")
            echo 1 ;;
        *)
            echo 0 ;;
    esac

}

sqlBackupsEnabled () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=1

    case "$(describeObject sql instances $instanceName $projectName $forceRefresh | jq -r '.settings.backupConfiguration.enabled')" in 
        "true")
            echo 1 ;;
        *)
            echo 0 ;;
    esac

}

sqlRecoveryEnabled () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=1

    case "$(describeObject sql instances $instanceName $projectName $forceRefresh | jq -r '.settings.backupConfiguration.binaryLogEnabled')" in 
        "true")
            echo 1 ;;
        *)
            echo 0 ;;
    esac

}

sqlMakePrimary () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    case "$(sqlIsReplica $instanceName $projectName)" in 
        1)
            gcloud sql instances promote-replica $instanceName --project=$projectName
            ;;
        *)
            echo "[$instanceName] is NOT a replica.  It CANNOT be promoted to a Primary instance."
            ;;
    esac

}

sqlEnableHA () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    case "$(sqlHAEnabled $instanceName $projectName)" in 
        0)  # HA isn't enabled, so turn it on.
            gcloud sql instances patch $instanceName --availability-type REGIONAL --project=$projectName
            ;;
        *)
            echo "HA for [$instanceName] is already enabled."
            ;;
    esac

}

sqlEnableRecovery () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    case "$(sqlRecoveryEnabled $instanceName $projectName)" in 
        0)  # Point-in-time recovery isn't enabled, so turn it on.
            gcloud sql instances patch --enable-bin-log $instanceName --project=$projectName
            ;;
        *)
            echo "HA for [$instanceName] is already enabled."
            ;;
    esac

}

sqlRunBackup () {

   # Build
    if [ $# -eq 4 ]; then
        local instanceName=$1
        local projectName=$2
        local backupLocation=$3
        local asyncFlg=$4
    else
        return
    fi

    local asyncCmd=
    case "$asyncFlg" in
        1) asyncCmd="--async" ;;
    esac

    case "$(sqlIsUp $instanceName $projectName)" in 
        1)  
            gcloud sql backups create --instance $instanceName --location $backupLocation --project=$projectName $asyncCmd
            ;;
        *)
            echo "Cannot run backup since [$instanceName] is down."
            ;;
    esac

}


# ----------------------------------------------------------------------------------------------------------
# INSTANCE functions
# ----------------------------------------------------------------------------------------------------------

instanceIsUp () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=1

    case "$(describeObject compute instances $instanceName $projectName $forceRefresh | jq -r '.status')" in 
        "RUNNING")
            echo 1 ;;
        *)
            echo 0 ;;
    esac

}

instanceIsDown () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=1

    case "$(describeObject compute instances $instanceName $projectName $forceRefresh | jq -r '.status')" in 
        "TERMINATED")
            echo 1 ;;
        *)
            echo 0 ;;
    esac

}

instanceIsPreemptible () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=1

    case "$(describeObject compute instances $instanceName $projectName $forceRefresh | jq -r '.scheduling.preemptible')" in 
        "true")
            echo 1 ;;
        "false")
            echo 0 ;;
        *)
            echo -1 ;;
    esac

}

listComputeInstances () {

    # Build
    local pcolumn="name"   # hard-coding for now...

    if [ $# -eq 1 ]; then
        local projectName=$1
    else
        return
    fi

    gcloudCmd="gcloud compute instances list --format=\"value("$pcolumn")\" --sort-by="$pcolumn" --quiet --project=$projectName"

    # Execute
    eval $gcloudCmd

}

getInstanceLabels () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject compute instances $instanceName $projectName $forceRefresh | jq -r '.labels'

}

getInstanceTags () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject compute instances $instanceName $projectName $forceRefresh | jq -r '.tags.items[]'

}

getInstanceDisks () {

    # Build
    if [ $# -eq 2 ]; then
        local instanceName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject compute instances $instanceName $projectName $forceRefresh | jq -r '.disks[].deviceName'

}

getComputeInstanceZone () {

    # Build
    if [ $# -eq 0 ]; then # use the default
        local instanceName="name"
    else                  # override the default
        local instanceName=$1
    fi

    gcloudCmd="gcloud compute instances list --format=\"value(zone)\" --filter=\"name=$instanceName\""

    # Execute
    eval $gcloudCmd

}

getComputeInstanceRegion () {

    # Build
    if [ $# -eq 0 ]; then # use the default
        local instance="name"
    else                  # override the default
        local instance=$1
    fi

    #gcloudCmd="gcloud compute instances list --format=\"value(region)\" --filter=\"name=$instance\""
    gcloudCmd="gcloud compute instances list --format=\"value(region)\" --filter=\"name=$instance\""

    # Execute
    eval $gcloudCmd

}

getComputeInstanceIPs () {

    # Build
    if [ $# -eq 2 ]; then
        local projectName=$1
        local instanceName=$2
    else
        return
    fi

    gcloudCmd="gcloud compute instances list --format=\"value(NAME,INTERNAL_IP,EXTERNAL_IP)\" --filter=\"name=$instanceName\" --project=$projectName"

    # Execute
    eval $gcloudCmd

}

getDiskSize () {

    # Build
    if [ $# -eq 2 ]; then
        local diskName=$1
        local projectName=$2
    else
        return
    fi

    local forceRefresh=0

    describeObject compute disks $diskName $projectName $forceRefresh | jq -r '.sizeGb'

}

# ----------------------------------------------------------------------------------------------------------
# GSUTIL functions
# ----------------------------------------------------------------------------------------------------------

listBuckets () {

    gsutilCmd="gsutil ls gs://"

    # Execute
    eval $gsutilCmd

}

getBucketLabels () {

    # Build
    if [ $# -eq 1 ]; then
        local bucketName=$1
    fi

    # Variables
    local key="Labels:"  # key to search for
    local foundKey=0

    # Create and populate file with detailed bucket info.
    local ustamp=$(date|md5|head -c12; echo)
#    local bucketInfo="/tmp/getBucketLabels_"$ustamp".txt"
    local bucketInfo=$tmpDir"/getBucketLabels_"$ustamp".txt"
    gsutil ls -L -b $bucketName >$bucketInfo

    # Process each bucket info line
    while read -r line
    do

        cleanLine=$(echo $line | sed -e 's/^[ \t]*//')

        if [ $foundKey -eq 0 ]
        then
            case "$cleanLine" in 
              ${key}*)

                if [ $(echo $cleanLine | awk '{ printf("%d", NF)}') -eq 1 ]
                then
                    echo $cleanLine
                    foundKey=1
                else
                    echo "No "$key
                    rm $bucketInfo
                    return
                fi
                ;;
            esac

        elif [[ $cleanLine != "}" ]]; then
            echo $cleanLine
        else
            echo $cleanLine
            rm $bucketInfo
            return
        fi

    done <$bucketInfo
}

# ----------------------------------------------------------------------------------------------------------
# BIGQUERY functions
# ----------------------------------------------------------------------------------------------------------

listBQdatasets () {

     # Build
    if [ $# -eq 1 ]; then
        local projectID=$1
    fi

    bqCmd="bq ls --project_id $projectID | awk 'NR>2'"  # Remove header

    # Execute
    eval $bqCmd

}

getBQdatasetsLabels () {

     # Build
    if [ $# -eq 1 ]; then
        local datasetName=$1
    fi

    bqCmd="bq show --format=json "$datasetName" | jq '.labels'"

    # Execute
    eval $bqCmd

}


# ----------------------------------------------------------------------------------------------------------
# PROJECT functions
# ----------------------------------------------------------------------------------------------------------

getProjectName () {

    # Build
    if [ $# -eq 1 ]; then
        local projectID=$1
    fi

    gcloudCmd="gcloud projects list --format=\"value(name)\" --filter=\"project_id = $projectID\" --quiet"

    # Execute
    eval $gcloudCmd

}

getProjectEnv () {

    # Build
    if [ $# -eq 1 ]; then
        local projectIDValue=$1
    fi

    gcloudCmd="gcloud projects describe $projectIDValue --format=\"value(labels.env)\""

    # Execute
    eval $gcloudCmd

}


# ----------------------------------------------------------------------------------------------------------
# CONFIGURATION functions
# ----------------------------------------------------------------------------------------------------------

# Default values for various configuration entries
getDefaultRegion () {

    gcloud config get-value compute/region 2> /dev/null   # stderr to null device to suppress info messages

}

getDefaultZone () {

    gcloud config get-value compute/zone 2> /dev/null   # stderr to null device to suppress info messages

}

getDefaultAccount () {
    
    gcloud config get-value core/account 2> /dev/null   # stderr to null device to suppress info messages

}

getDefaultProject () {

    gcloud config get-value core/project 2> /dev/null   # stderr to null device to suppress info messages

}

getDefaultDisableUsageReporting () {

    gcloud config get-value core/disable_usage_reporting 2> /dev/null   # stderr to null device to suppress info messages

}

getCurrentGCVersion () {

    gcloud info --format=json | jq -r '.basic.version'

}

getGCLogDirectory () {

    gcloud info --format=json | jq -r '.logs.logs_dir'

}

getActiveConfig () {

    gcloud info --format=json | jq -r '.config.active_config_name'

}


# ----------------------------------------------------------------------------------------------------------
# ACTION functions
# ----------------------------------------------------------------------------------------------------------

# CREATE
createSnapshot () {

   # Build
    if [ $# -eq 3 ]; then
        local instanceName=$1
        local projectName=$2
        local snapshotDesc="$3"
    else
        echo "BUG: snapshotDesc parameter can't contain spaces, rerun without spaces in the description."
        return
    fi

    local now=$(date +%Y%m%d%H%M%S)
    local _region=$(getDefaultRegion)
    local _zone=$(getDefaultZone)

    gcloudCmd="gcloud compute disks snapshot $instanceName --project=$projectName --description=\"$snapshotDesc\" --snapshot-names=$instanceName-snapshot-$now --zone=$_zone --storage-location=$_region"

    # Execute
    eval $gcloudCmd

}

createDiskFromSnapshot () {

   # Build
    if [ $# -eq 3 ]; then
        local diskName=$1
        local snapshotName=$2
        local projectName=$3
    else
        return
    fi

    local _zone=$(getDefaultZone)

    gcloudCmd="gcloud compute disks create $diskName  --source-snapshot $snapshotName --project=$projectName --zone=$_zone"

    # Execute
    eval $gcloudCmd

}

createDisk () {

    # Build
    if [ $# -eq 3 ]; then
        local diskName=$1
        local DiskSizeGb=$2
        local projectName=$3
    else
        return
    fi

    # Basic disk.  Lots of opportunity to add disk options...

    local _zone=$(getDefaultZone)
    gcloud compute disks create $diskName --size=$DiskSizeGb --project=$projectName --zone=$_zone

}


# START / STOP
shutdownInstance () {

   # Build
    if [ $# -eq 3 ]; then
        local instanceName=$1
        local projectName=$2
        local asyncFlg=$3
    else
        return
    fi


    local asyncCmd=
    case "$asyncFlg" in
        1) asyncCmd="--async" ;;
    esac

    
    local _zone=$(getDefaultZone)

    case "$(instanceIsUp $instanceName $projectName)" in 
        1)
            gcloud compute instances stop $instanceName --project=$projectName --zone=$_zone $asyncCmd
            ;;
        *)
            echo "[$instanceName] is already down..."
            ;;
    esac

}

startupInstance () {

   # Build
    if [ $# -eq 3 ]; then
        local instanceName=$1
        local projectName=$2
        local asyncFlg=$3
    else
        return
    fi

    local asyncCmd=
    case "$asyncFlg" in
        1) asyncCmd="--async" ;;
    esac

    local _zone=$(getDefaultZone)

    case "$(instanceIsDown $instanceName $projectName)" in 
        1)
            gcloud compute instances start $instanceName --project=$projectName --zone=$_zone $asyncCmd
            ;;
        *)
            echo "[$instanceName] is already running..."
            ;;
    esac

}

shutdownClusterNodes () {

   # Build
    if [ $# -eq 3 ]; then
        local clusterName=$1
        local projectName=$2
        local asyncFlg=$3
    else
        return
    fi

    case "$(clusterIsUp $clusterName $projectName)" in 

        1)  # Cluster is active

            # Shutdown worker nodes
            for workerNode in $(getDataprocWorkerNodes $clusterName $projectName); 
            do
                case "$(instanceIsUp $workerNode $projectName)" in
                    1)  shutdownInstance $workerNode $projectName $asyncFlg
                        ;;
                    0)  echo "Worker node [$workerNode] is not running..."
                        ;;
                esac
            done

            # Shutdown master node
            masterNode=$(getDataprocMasterNode $clusterName $projectName)
            case "$(instanceIsUp $masterNode $projectName)" in
                1)  shutdownInstance $masterNode $projectName $asyncFlg
                    ;;
                0)  echo "Master node [$masterNode] is not running..."
                    ;;
            esac

            #echo "Cluster node shutdown begun..."
            waitForNodeShutdown $clusterName $projectName
            #echo "Cluster node shutdown complete..."

            ;;

        *)
            echo "Cluster [$clusterName] is not running..."
            ;;

    esac

}

startupClusterNodes () {

   # Build
    if [ $# -eq 3 ]; then
        local clusterName=$1
        local projectName=$2
        local asyncFlg=$3
    else
        return
    fi

    case "$(clusterIsUp $clusterName $projectName)" in 

        1)  # Cluster is active
        
            # Start master node
            masterNode=$(getDataprocMasterNode $clusterName $projectName)
            case "$(instanceIsDown $masterNode $projectName)" in
                1)  startupInstance $masterNode $projectName $asyncFlg
                    ;;
                0)  echo "Master node [$masterNode] is already running..."
                    ;;
            esac

            # Start worker nodes
            for workerNode in $(getDataprocWorkerNodes $clusterName $projectName); 
            do
                case "$(instanceIsDown $workerNode $projectName)" in
                    1)  startupInstance $workerNode $projectName $asyncFlg
                        ;;
                    0)  echo "Worker node [$workerNode] is already running..."
                        ;;
                esac
            done

            #echo "Cluster node startup begun..."
            waitForNodeStartup $clusterName $projectName
            #echo "Cluster node startup complete..."

            ;;

        *)
            echo "Cluster [$clusterName] is not running..."
            ;;

    esac

}

# MODIFY
resizeDisk () {

    # Build
    if [ $# -eq 3 ]; then
        local diskName=$1
        local newDiskSizeGb=$2
        local projectName=$3
    else
        return
    fi

    local currentDiskSize=$(getDiskSize $diskName $projectName)

    if [ $newDiskSizeGb -le $currentDiskSize ]; then
        echo "New size [$newDiskSizeGb] must be > Current size [$currentDiskSize]"
        return
    else
        local _zone=$(getDefaultZone)
        gcloud compute disks resize $diskName --size=$newDiskSizeGb --project=$projectName --zone=$_zone
    fi
}
