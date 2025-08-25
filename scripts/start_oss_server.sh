#!/bin/bash

# exit immediately if a command exits with a non-zero status
set -e
# fail if trying to reference a variable that is not set.
set -u

IVY_VERSION=${IVY_VERSION_USED:-4}
coordinatorPort="9712"
ivoryDirectory=""
initSetup="false"
forceCleanup="false"
help="false"
stop="false"
distributed="false"
allowExternalAccess="false"
while getopts "d:p:hcsxe" opt; do
  case $opt in
    d) ivoryDirectory="$OPTARG"
    ;;
    c) initSetup="true"
       forceCleanup="true"
    ;;
    h) help="true"
    ;;
    s) stop="true"
    ;;
    x) distributed="true"
    ;;    
    e) allowExternalAccess="true"
    ;;
    p) coordinatorPort="$OPTARG"
    ;;
  esac

  # Assume empty string if it's unset since we cannot reference to
  # an unset variabled due to "set -u".
  case ${OPTARG:-""} in
    -*) echo "Option $opt needs a valid argument. use -h to get help."
    exit 1
    ;;
  esac
done

red=`tput setaf 1`
green=`tput setaf 2`
reset=`tput sgr0`

if [ "$help" == "true" ]; then
    echo "${green}sets up and launches a postgres server with extension installed on port $coordinatorPort."
    echo "${green}start_oss_server -d <postgresDir> [-c] [-s] [-x] [-e] [-p <port>]"
    echo "${green}<postgresDir> is the data directory for your postgres instance with extension"
    echo "${green}[-c] - optional argument. FORCE cleanup - removes all existing data and reinitializes"
    echo "${green}[-s] - optional argument. Stops all servers and exits"
    echo "${green}[-x] - start oss server with documentdb_distributed extension"
    echo "${green}[-e] - optional argument. Allows IvorySQL access from any IP address"
    echo "${green}[-p <port>] - optional argument. specifies the port for the coordinator"
    echo "${green}if postgresDir not specified assumed to be /data"
    exit 1;
fi

if ! [[ "$coordinatorPort" =~ ^[0-9]+$ ]] || [ "$coordinatorPort" -lt 0 ] || [ "$coordinatorPort" -gt 65535 ]; then
    echo "${red}Invalid port value $coordinatorPort, must be a number between 0 and 65535.${reset}"
    exit 1
fi

# Check if the port is already in use
if lsof -i:"$coordinatorPort" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "${red}Port $coordinatorPort is already in use. Please specify a different port.${reset}"
    exit 1
fi

if [ "$distributed" == "true" ]; then
  extensionName="documentdb_distributed"
else
  extensionName="documentdb"
fi

preloadLibraries="pg_documentdb_core, pg_documentdb"

if [ "$distributed" == "true" ]; then
  preloadLibraries="citus, $preloadLibraries, pg_documentdb_distributed"
fi

source="${BASH_SOURCE[0]}"
while [[ -h $source ]]; do
   scriptroot="$( cd -P "$( dirname "$source" )" && pwd )"
   source="$(readlink "$source")"

   # if $source was a relative symlink, we need to resolve it relative to the path where the
   # symlink file was located
   [[ $source != /* ]] && source="$scriptroot/$source"
done

scriptDir="$( cd -P "$( dirname "$source" )" && pwd )"

. $scriptDir/utils.sh

if [ -z $ivoryDirectory ]; then
    ivoryDirectory="/data"
fi

# Only initialize if directory doesn't exist, is empty, or doesn't contain a valid IvorySQL data directory
# Check for IVY_VERSION file which indicates a valid IvorySQL data directory
if [ ! -d "$ivoryDirectory" ]; then
    # Directory doesn't exist, we need to initialize
    echo "${green}Directory $ivoryDirectory doesn't exist, will initialize IvorySQL data directory${reset}"
    initSetup="true"
elif [ ! -f "$ivoryDirectory/IVY_VERSION" ]; then
    # Directory exists but no IVY_VERSION file
    if [ "$(ls -A "$ivoryDirectory" 2>/dev/null)" ]; then
        # Directory exists and is not empty but doesn't have IVY_VERSION
        # This might be a corrupted or incompatible data directory
        echo "${red}Warning: Directory $ivoryDirectory exists but doesn't appear to contain a valid IvorySQL data directory.${reset}"
        echo "${red}Use -c flag to force cleanup and re-initialization, or specify a different directory with -d.${reset}"
        exit 1
    else
        # Directory exists but is empty, we can initialize
        echo "${green}Directory $ivoryDirectory is empty, will initialize IvorySQL data directory${reset}"
        initSetup="true"
    fi
else
    # Directory exists and has IVY_VERSION, check if it's compatible
    echo "${green}Found existing IvorySQL data directory at $ivoryDirectory${reset}"
fi

# We stop the coordinator first and the worker node servers
# afterwards. However this order is not required and it doesn't
# really matter which order we choose to stop the active servers.
echo "${green}Stopping any existing postgres servers${reset}"
StopServer $ivoryDirectory

if [ "$stop" == "true" ]; then
  exit 0;
fi

echo "InitDatabaseExtended $initSetup $ivoryDirectory"

if [ "$initSetup" == "true" ]; then
    InitDatabaseExtended $ivoryDirectory "$preloadLibraries"
fi

# Update IvorySQL configuration to allow access from any IP
if [ "$allowExternalAccess" == "true" ]; then
  postgresConfigFile="$ivoryDirectory/postgresql.conf"
  hbaConfigFile="$ivoryDirectory/pg_hba.conf"

  echo "${green}Configuring IvorySQL to allow access from any IP address${reset}"
  echo "listen_addresses = '*'" >> $postgresConfigFile
  echo "host all all 0.0.0.0/0 scram-sha-256" >> $hbaConfigFile
  echo "host all all ::0/0 scram-sha-256" >> $hbaConfigFile
fi

userName=$(whoami)
sudo mkdir -p /var/run/postgresql
sudo chown -R $userName:$userName /var/run/postgresql

StartServer $ivoryDirectory $coordinatorPort

if [ "$initSetup" == "true" ]; then
  SetupPostgresServerExtensions "$userName" $coordinatorPort $extensionName
fi

if [ "$distributed" == "true" ]; then
  psql -p $coordinatorPort -d postgres -c "SELECT citus_set_coordinator_host('localhost', $coordinatorPort);"
  AddNodeToCluster $coordinatorPort $coordinatorPort
fi
. $scriptDir/setup_psqlrc.sh