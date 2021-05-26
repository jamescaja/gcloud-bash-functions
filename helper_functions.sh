#
# Initialization
#

#
# Functions
#
confirmContinue () {

    if [ $# -eq 0 ]; then # use the default
        local prompt="Continue"
    else                  # override the default
        local prompt=$1
    fi

    read -p "$prompt (y/N)? " CONT

    goForIt=${CONT:-"no"}  # default to NO

#    goForIt=${goForIt,,} # tolower
    if [[ $goForIt =~ ^(yes|y| ) ]]; then
        echo 1
    else
        echo 0
    fi

}


timeOutReached () {

    # Build
    if [ $# -eq 2 ]; then
        local timerStart=$1
        local timeoutSeconds=$2
    else
    echo "Bad argument list..."
        return
    fi

    local now=$(date +%Y%m%d%H%M%S)

    local elapsedTime=$now-$timerStart

    echo "    timerStart: "$timerStart
    echo "timeoutSeconds: "$timeoutSeconds
    echo "           now: "$now
    echo "   elapsedTime: "$elapsedTime

# syntax issue - comment for now
    # if [[ $elapsedTime >= $timeoutSeconds ]]; then
    #     echo 1
    # else
    #     echo 0
    # fi

}