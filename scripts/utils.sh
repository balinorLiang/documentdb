#!/bin/bash

# fail if trying to reference a variable that is not set.
set -u
# exit immediately if a command exits with a non-zero status
set -e

# trap to print line number on error
error() {
  local parent_lineno="$1"
  local message="${2:-x}"
  local code="${3:-1}"
  if [[ -n "$message" ]] ; then
    echo "Error on or near line ${parent_lineno}: ${message}; exiting with status ${code}"
  else
    echo "Error on or near line ${parent_lineno}; exiting with status ${code}"
  fi
  exit "${code}"
}
trap 'error ${LINENO}' ERR

function GetPostgresPath()
{
  local ivyVersion=$1
  echo "/var/local/ivorysql/ivory-$ivyVersion/bin"
}

function GetPostgresSourceRef()
{
  local ivyVersion=$1
  if [ "$ivyVersion" == "3" ]; then
    # This maps to REL_16_2:b78fa8547d02fc72ace679fb4d5289dccdbfc781
    IvorySQL_REF="IvorySQL_3.4"
  elif [ "$ivyVersion" == "2" ]; then
    # This maps to REL15_3:8382864eb5c9f9ebe962ac20b3392be5ae304d23
    IvorySQL_REF="Ivory_REL_2_3"
  else
    echo "Invalid PG Version specified $ivyVersion";
    exit 1;
  fi

  echo $IvorySQL_REF
}

function GetPGCTL()
{
  local ivyVersion=${IVY_VERSION:-4}
  echo ${pgctlPath:-$(GetPostgresPath $ivyVersion)/pg_ctl}
}

function GetInitDB()
{
  local ivyVersion=${IVY_VERSION:-4}
  echo $(GetPostgresPath $ivyVersion)/initdb
}

function StopServer()
{
  local _directory=$1
  local _extraOptions=${2:-""}

  $(GetPGCTL) stop -D $_directory $_extraOptions || true;
  echo "Stopped all PG instances on $_directory";
}

function StartServer()
{
  local _directory=$1
  local _port=$2
  local _logPath=${3:-$_directory/pglog.log}
  local _pgctlPath=$(GetPGCTL)

  echo "Starting postgres in $_directory"
  echo "Calling: $_pgctlPath start -D $_directory -o \"-p $_port -l $_logPath\""
  $_pgctlPath start -D $_directory -o "-p $_port" -l $_logPath
}


function SetupPostgresServerExtensions()
{
  local user=$1
  local port=$2
  local extensionName=$3
  local extensionVersion=${4:-}
  
  local versionString="";
  if [ "$extensionVersion" != "" ]; then
    versionString="WITH VERSION '${extensionVersion}'";
  fi

  echo "create extension $extensionName on port $port with version '${extensionVersion:-latest}'."
  psql -p $port -U $user -d postgres -X -c "CREATE EXTENSION $extensionName $versionString CASCADE;"

  psql -p $port -U $user -d postgres -c "SELECT * FROM pg_extension WHERE extname = '$extensionName';"
}


function InitDatabaseExtended()
{
  local _directory=$1
  local _preloadLibraries=$2

  echo "Initializing IvorySQL database in $_directory with preload libraries: $_preloadLibraries"

  if [ -d "$_directory" ]; then
    echo "Removing contents of $_directory"
    rm -rf $_directory/*
    rm -rf $_directory/.[!.]*
  fi
  
  if [ ! -d "$_directory" ]; then
    echo "Creating directory $_directory"
    mkdir -p $_directory
  fi

  echo "Calling initdb for $_directory"
  $(GetInitDB) -D $_directory
  SetupPostgresConfigurations $_directory "$_preloadLibraries"
}


function SetupPostgresConfigurations()
{
  local installdir=$1;
  local preloadLibraries=$2;
  requiredLibraries="pg_cron, ${preloadLibraries}";
  echo shared_preload_libraries = \'$requiredLibraries\' | tee -a $installdir/postgresql.conf
  echo cron.database_name = \'postgres\' | tee -a $installdir/postgresql.conf
  echo documentdb.enableBackgroundWorker = 'true' | tee -a $installdir/postgresql.conf
  echo documentdb.enableBackgroundWorkerJobs = 'true' | tee -a $installdir/postgresql.conf
  echo ssl = off | tee -a $installdir/postgresql.conf
}


function AddNodeToCluster()
{
  local _coordinatorPort=$1
  local _nodePort=$2

  psql -d postgres -p $_coordinatorPort -c "SELECT citus_add_node('localhost', $_nodePort);"
  psql -d postgres -p $_coordinatorPort -c "SELECT citus_set_node_property('localhost', $_nodePort, 'shouldhaveshards', true);"
}