#!/bin/bash

# define the exit codes
SUCCESS=0
ERR_PUBLISH=55
ERR_MAXENT=33
ERR_GETSAMPLES=44
ERR_TAR=77

# source the ciop functions (e.g. ciop-log, ciop-getparam)
source ${ciop_job_include}

###############################################################################
# Trap function to exit gracefully
# Globals:
#   SUCCESS
#   ERR_PUBLISH
# Arguments:
#   None
# Returns:
#   None
###############################################################################
function cleanExit ()
{
  local retval=$?
  local msg=""
  case "${retval}" in
    ${SUCCESS}) msg="Processing successfully concluded";;
    ${ERR_PUBLISH}) msg="Failed to publish the results";;
    ${ERR_MAXENT}) msg="Failed to run mxent model";;
    ${ERR_GETSAMPLES}) msg="Failed to retrieve vegetation samples from external server (SYNBIOSYS)";;
    ${ERR_TAR}) msg="Failed to TAR the results";;
    *) msg="Unknown error";;
  esac

  [ "${retval}" != "0" ] && ciop-log "ERROR" "Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"
  exit ${retval}
}


###############################################################################
# Log an input string to the log file
# Globals:
#   None
# Arguments:
#   input reference to log
# Returns:
#   None
###############################################################################
function log_input()
{
  local input=${1}
  ciop-log "INFO" "processing input: ${input}"
}

###############################################################################
# Pass the input string to the next node, without storing it on HDFS
# Globals:
#   None
# Arguments:
#   input reference to pass
# Returns:
#   0 on success
#   ERR_PUBLISH if something goes wrong 
###############################################################################
function pass_next_node()
{
  local input=${1}
  echo "${input}" | ciop-publish -s || return ${ERR_PUBLISH}
}

###############################################################################
# Main function to process an input reference
# Globals:
#   None
# Arguments:
#   input reference to process
# Returns:
#   0 on success
#   ERR_PUBLISH if something goes wrong
###############################################################################
function main()
{
  export JAVA_HOME="/usr/lib/jvm/jre-1.8.0"
  export PATH=/usr/lib/jvm/jre-1.8.0/bin:$PATH 

  predictors="$(ciop-getparam predictors)"
  IFS=","
  predictordir="${TMPDIR}/predictors"
  mkdir ${predictordir}
  for predictor in ${predictors}
  do
	cp /data/predictors/${predictor}.asc ${predictordir}
  done  
  
  type="$(ciop-getparam type)"
  obsurl="https://www.synbiosys.alterra.nl/nextgeoss/service/getdistribution.aspx?eunistype=${type}&target=csv"
  obspath=${TMPDIR}/${type}.csv
  ciop-log "INFO" "obspath=${obspath}"
  curl -o ${obspath} ${obsurl}
  exitcode=$?
  if [ "${exitcode}" -ne 0 ] 
  then 
	exit ${ERR_GETSAMPLES}
  fi
  

  # Log the input
  log_input ${input}
  maxentjar="${_CIOP_APPLICATION_PATH}/maxent/bin/maxent.jar"

  outputpath="${TMPDIR}/output"
  mkdir ${outputpath}
  java -jar ${maxentjar}  ${predictordir} ${obspath} ${outputpath} 
  exitcode=$?
  if [ "${exitcode}" -ne 0 ] 
  then 
	exit ${ERR_MAXENT}
  fi

  # zip all results
  resultZipFile="${TMPDIR}/maxent_${type}.zip"
  tar czf ${resultZipFile} ${outputpath}
  exitcode=$?
  if [ "${exitcode}" -ne 0 ] 
  then 
	exit ${ERR_TAR}
  fi

  ciop-publish -m ${resultZipFile}
  exitcode=$?
  if [ "${exitcode}" -ne 0 ] 
  then 
	exit ${ERR_PUBLISH}
  fi

  ciop-publish -m ${outputpath}/maxentResults.csv
  exitcode=$?
  if [ "${exitcode}" -ne 0 ] 
  then 
	exit ${ERR_PUBLISH}
  fi
  for graphFile in $(find ${outputpath}/plots/ -name *.png)
  do
	ciop-publish -m ${graphFile}
        exitcode=$?
        if [ "${exitcode}" -ne 0 ] 
        then 
	   exit ${ERR_PUBLISH}
        fi
  done  
  exit ${SUCCESS}
}


