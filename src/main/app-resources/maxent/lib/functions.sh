#!/bin/bash

# define the exit codes
SUCCESS=0
ERR_PUBLISH=55
ERR_MAXENT=33
ERR_GETSAMPLES=44
ERR_TAR=77
ERR_GEOSERVER=88

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
    ${ERR_GEOSERVER_CURL}) msg="Failed to publish the resulting maps on GeoServer. CURL returned an error.";;
    ${ERR_GEOSERVER_HTTP}) msg="Failed to publish the resulting maps on GeoServer. GeoServer returned a HTTP error.";;
    ${ERR_GEOSERVER_CREATEWORKSPACE}) msg="Failed to publish the resulting maps on GeoServer. Could not create a geoserver workspace.";;
    ${ERR_GEOSERVER_GDALWARP}) msg="Failed to publish the resulting maps on GeoServer. GDALWARP failed to reproject maxent ASC file into GeoTIFF ETRS.";;
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

  # get input and output parameters
  type="$(ciop-getparam type)"
  predictors="$(ciop-getparam predictors)"

  dateID=$(date +%Y%m%d)
  dateTimeID="${dateID}_$(date +%H%M%S)"
  resultID="maxent_${dateTimeID}_${type}"



  #
  # copy selected predictor maps
  #
  currentTime=$(date +%s%N)
  IFS=","
  predictordir="${TMPDIR}/predictors"
  predictorCacheDir="${predictordir}/maxent.cache"
  mkdir ${predictordir}
  mkdir ${predictorCacheDir}
  for predictor in ${predictors}
  do
	cp /data/predictors/${predictor}.asc ${predictordir}
	cp /data/predictors/maxent.cache/${predictor}.info ${predictorCacheDir}
	cp /data/predictors/maxent.cache/${predictor}.mxe ${predictorCacheDir}
  done 
  timeElapsed=$((($(date +%s%N) - $currentTime)/1000000))
  echo "Predictor file copying took $timeElapsed mSeconds"



  #
  # retrieve samples for selected EUNIS vegetation type
  #
  currentTime=$(date +%s%N)
  obsurl="https://www.synbiosys.alterra.nl/nextgeoss/service/getdistribution.aspx?eunistype=${type}&target=csv"
  obspath=${TMPDIR}/${type}.csv
  ciop-log "INFO" "obspath=${obspath}"
  curl -o ${obspath} ${obsurl}
  exitcode=$?
  if [ "${exitcode}" -ne 0 ] 
  then 
	exit ${ERR_GETSAMPLES}
  fi
  timeElapsed=$((($(date +%s%N) - $currentTime)/1000000))
  echo "Retrieving samples from SYNBIOSYS server took $timeElapsed mSeconds"
  


  #
  # run MAXENT
  #
  currentTime=$(date +%s%N)
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
  timeElapsed=$((($(date +%s%N) - $currentTime)/1000000))
  echo "Running maxent took $timeElapsed mSeconds"



  #
  # zip all results
  #
  currentTime=$(date +%s%N)
  resultZipFile="${TMPDIR}/${resultID}.zip"
  cd ${outputpath}
  # exclude the actual samples from the exported zip (samples are not publically accessible)
  rm *sample*.csv 
  zip -r -q ${resultZipFile} ./*
  exitcode=$?
  if [ "${exitcode}" -ne 0 ] 
  then 
	exit ${ERR_TAR}
  fi
  timeElapsed=$((($(date +%s%N) - $currentTime)/1000000))
  echo "Zipping results took $timeElapsed mSeconds"



  #
  # put maps on geoserver 
  #
  currentTime=$(date +%s%N)

  # create geoserver workspace (if it does not already exist)
  # to facilitate scheduled clean up of geoserver layers the workspace is given a name which includes a date 
  workspace="nextgeoss_${dateID}"
  httpStatus=$(curl -v -u henne002:floortje -v -XPOST -H "Content-type: text/xml" -d "<workspace><name>${workspace}</name></workspace>" http://www.synbiosys.alterra.nl:8080/geoserver/rest/workspaces -w '%{http_code}')
  if [ ${httpStatus} -ne 200 ] && [ ${httpStatus} -ne 201 ] && [ ${httpStatus} -ne 401 ]
  then
  	exit ${ERR_GEOSERVER_CREATEWORKSPACE} 
  fi

  # upload fraction map
  fractionMap="${type}"
  gtifFractionMap="${outputpath}/${resultID}_fraction.tiff"
  gdalwarp -t_srs EPSG:3035 ${outputpath}/${fractionMap}.asc ${gtifFractionMap}
  if [ "${exitcode}" -ne 0 ] 
  then 
	exit ${ERR_GEOSERVER_GDALWARP}
  fi
  httpStatus=$(curl -v -u henne002:floortje -XPUT -H Content-type:image/tiff --data-binary @${gtifFractionMap} http://www.synbiosys.alterra.nl:8080/geoserver/rest/workspaces/${workspace}/coveragestores/${resultID}_fraction/file.geotiff -w '%{http_code}')
  exitcode=$?
  if [ "${exitcode}" -ne 0 ] 
  then 
	exit ${ERR_GEOSERVER_CURL}
  fi
  if [ ${httpStatus} -ne 200 ] && [ ${httpStatus} -ne 201 ]
  then
  	exit ${ERR_GEOSERVER_HTTP} 
  fi

  # upload threshholded map
  threshholdMap="${type}_thresholded"
  gtifThreshholdMap="${outputpath}/${resultID}_threshold.tiff"
  gdalwarp -t_srs EPSG:3035 ${outputpath}/${threshholdMap}.asc ${gtifThreshholdMap}
  if [ "${exitcode}" -ne 0 ] 
  then 
	exit ${ERR_GEOSERVER_GDALWARP}
  fi
  httpStatus=$(curl -v -u henne002:floortje -XPUT -H Content-type:image/tiff --data-binary @${gtifThreshholdMap} http://www.synbiosys.alterra.nl:8080/geoserver/rest/workspaces/${workspace}/coveragestores/${resultID}_threshold/file.geotiff -w '%{http_code}')
  exitcode=$?
  if [ "${exitcode}" -ne 0 ] 
  then 
	exit ${ERR_GEOSERVER_CURL}
  fi
  if [ ${httpStatus} -ne 200 ] && [ ${httpStatus} -ne 201 ]
  then
  	exit ${ERR_GEOSERVER_HTTP} 
  fi

  set +x
  timeElapsed=$((($(date +%s%N) - $currentTime)/1000000))
  echo "Uploading and publishing maps on geoserver took $timeElapsed mSeconds"



  #
  # publish results
  #
  currentTime=$(date +%s%N)
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
  timeElapsed=$((($(date +%s%N) - $currentTime)/1000000))
  echo "Publishing results took $timeElapsed mSeconds"

  exit ${SUCCESS}
}


