#!/bin/bash
#source ~/.profile

#export CLOUDSDK_ACTIVE_CONFIG_NAME="admin"

# Add all libraries for the functions to test here
source ./gcloud_functions.sh
source ./helper_functions.sh

usage() {

    echo "Available Options:
     -f     Function name
     -[1-5] Parameter number (optional)

     Examples:
        ./$(basename $0) -f getDataprocNodes -1 cdh-hadoop-preprod -2 exp-cdh-preprod
        ./$(basename $0) -f getActiveConfig

    "
}

# Process command line arguments
parameterCount=-1
while getopts hf:1:2:3:4:5: name
do
    case $name in
        h) usage;;
        f) functionName="$OPTARG";;
        1) parameter1="$OPTARG";;
        2) parameter2="$OPTARG";;
        3) parameter3="$OPTARG";;
        4) parameter4="$OPTARG";;
        5) parameter5="$OPTARG";;
        ?) echo "Invalid Option Specified: $name"
            usage
            exit 1;;
    esac
    let parameterCount+=1
done


# Execute function w/appropriate parameters
case $parameterCount in
   -1) usage ;;
    0) Result=$($functionName) ;;
    1) Result=$($functionName $parameter1) ;;
    2) Result=$($functionName $parameter1 $parameter2) ;;
    3) Result=$($functionName $parameter1 $parameter2 $parameter3) ;;
    4) Result=$($functionName $parameter1 $parameter2 $parameter3 $parameter4) ;;
    5) Result=$($functionName $parameter1 $parameter2 $parameter3 $parameter4 $parameter5) ;;
    *) echo "Max # of parameters exceeded.  Edit "$(basename $0)" to add more."
       exit 1
       ;;
esac

# Print function call result
echo $Result
